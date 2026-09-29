// Opt-in sharing to the separately deployed Usage Tracker website. Only daily
// aggregates leave this Mac, authenticated with a dedicated installation token.
import Combine
import Foundation
import Security

enum LeaderboardConfiguration {
    static let origin = URL(string: "https://usage.beffa.xyz")!
}

enum LeaderboardBilling: String, Codable, CaseIterable, Identifiable {
    case unclassified, subscription, api
    var id: String { rawValue }
    var label: String {
        switch self {
        case .unclassified: return "Not shared"
        case .subscription: return "Subscription"
        case .api: return "API billed"
        }
    }
}

struct SharedUsageBucket: Codable {
    let day: String
    let provider: String
    let model: String
    var inputTokens = 0
    var outputTokens = 0
    var cacheReadTokens = 0
    var cacheWriteTokens = 0
    var cacheWrite1hTokens = 0
    var billing: String = "unclassified"

    var key: String { "\(day)|\(provider)|\(model)" }
}

struct LeaderboardSnapshot: Encodable {
    let schemaVersion = 1
    let consent = true
    let displayName: String
    let buckets: [SharedUsageBucket]
}

struct LeaderboardState: Codable {
    var displayName = ""
    var website = ""
    var claudeBilling: LeaderboardBilling = .unclassified
    var codexBilling: LeaderboardBilling = .unclassified
    var enabled = false
    var pendingRemoval = false
    var token = ""
    var lastSynced: Date?
    // The scanners retain 31 days. Keep older aggregate days locally so a full
    // replacement snapshot does not erase the leaderboard's all-time history.
    var archive: [SharedUsageBucket] = []
}

enum LeaderboardError: LocalizedError {
    case message(String)
    case http(String, retryAfter: TimeInterval?)
    var errorDescription: String? {
        switch self {
        case .message(let text), .http(let text, _): return text
        }
    }
}

/// An origin, not an arbitrary endpoint. Local HTTP is useful for development;
/// all other origins must use TLS. Credentials must never follow redirects.
func leaderboardOrigin(_ text: String) throws -> URL {
    guard let parts = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
          let host = parts.host, !host.isEmpty,
          parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
          parts.path.isEmpty || parts.path == "/",
          parts.scheme == "https" || (parts.scheme == "http" && ["localhost", "127.0.0.1", "[::1]", "::1"].contains(host)),
          let url = parts.url else {
        throw LeaderboardError.message("Enter the website’s HTTPS address, without a path or query.")
    }
    return url
}

func leaderboardDisplayName(_ text: String) throws -> String {
    let name = text.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
    guard (2...32).contains(name.utf16.count),
          name.range(of: "^[\\p{L}\\p{N} _.-]+$", options: .regularExpression) != nil else {
        throw LeaderboardError.message("Use 2–32 letters, numbers, spaces, dots, underscores or hyphens.")
    }
    return name
}

/// Preserve completed historical days, replace the complete recent UTC window,
/// and never add a repeated scan to a previously counted day.
func archiveLeaderboardUsage(_ records: [TokenRecord], previous: [SharedUsageBucket], now: Date = Date()) -> [SharedUsageBucket] {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let today = calendar.startOfDay(for: now)
    let from = calendar.date(byAdding: .day, value: -29, to: today)!
    let formatter = DateFormatter()
    formatter.calendar = calendar
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = calendar.timeZone
    formatter.dateFormat = "yyyy-MM-dd"
    let fromDay = formatter.string(from: from)
    var buckets: [String: SharedUsageBucket] = [:]
    for bucket in previous where bucket.day < fromDay { buckets[bucket.key] = bucket }
    for record in records where record.date >= from && record.date <= now {
        // The website's two sources are Claude Code and Codex. OpenCode has its
        // own mixed authentication paths and remains in the app's local charts.
        guard record.source == .claudeCode || record.source == .codex else { continue }
        let provider = record.source == .claudeCode ? "claude" : "codex"
        let day = formatter.string(from: record.date)
        let key = "\(day)|\(provider)|\(record.model)"
        var bucket = buckets[key] ?? SharedUsageBucket(day: day, provider: provider, model: record.model)
        let write1h = min(max(0, record.cacheWrite1h), max(0, record.cacheWrite))
        bucket.inputTokens += max(0, record.input)
        bucket.outputTokens += max(0, record.output)
        bucket.cacheReadTokens += max(0, record.cacheRead)
        bucket.cacheWriteTokens += max(0, record.cacheWrite - write1h)
        bucket.cacheWrite1hTokens += write1h
        buckets[key] = bucket
    }
    return buckets.values.sorted { $0.key < $1.key }
}

func leaderboardSnapshot(_ state: LeaderboardState) -> LeaderboardSnapshot {
    let buckets = state.archive.compactMap { bucket -> SharedUsageBucket? in
        let mode = bucket.provider == "claude" ? state.claudeBilling : state.codexBilling
        guard mode != .unclassified else { return nil }
        var shared = bucket
        shared.billing = mode.rawValue
        return shared
    }
    return LeaderboardSnapshot(displayName: state.displayName, buckets: buckets)
}

private final class LeaderboardRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

@MainActor
final class LeaderboardStore: ObservableObject {
    @Published private(set) var state = LeaderboardState()
    @Published private(set) var inFlight = false
    @Published private(set) var lastError: String?
    @Published private(set) var nextAttemptAt = Date.distantPast
    @Published private(set) var status = "Sharing is off. Your usage stays on this Mac."

    private let stateURL: URL
    private var latestRecords: [TokenRecord]?
    private var subscription: AnyCancellable?
    private var failures = 0
    private var retryNotBefore = Date.distantPast
    private let session = URLSession(configuration: .ephemeral, delegate: LeaderboardRedirectPolicy(), delegateQueue: nil)

    convenience init(tokens: TokenStore) {
        self.init(records: tokens.$records.dropFirst().eraseToAnyPublisher())
    }

    init(records: AnyPublisher<[TokenRecord], Never>, stateURL: URL? = nil) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.stateURL = stateURL ?? support.appendingPathComponent("ClaudeUsageBar/leaderboard.json")
        if FileManager.default.fileExists(atPath: self.stateURL.path) {
            do { state = try JSONDecoder().decode(LeaderboardState.self, from: Data(contentsOf: self.stateURL)) }
            catch { lastError = "Couldn’t read leaderboard settings. Sharing is paused: \(error.localizedDescription)" }
        }
        if state.pendingRemoval { status = "Removal pending. Retrying when connected." }
        else if state.enabled { status = "Waiting for local usage to load…" }
        subscription = records.sink { [weak self] records in
            self?.latestRecords = records
            self?.tick()
        }
        Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        tick() // Pending removals do not need to wait for the scanners.
    }

    func saveProfile(name: String, claude: LeaderboardBilling, codex: LeaderboardBilling) {
        guard !state.pendingRemoval else { return }
        if state.enabled {
            enable(name: name, website: state.website, claude: claude, codex: codex)
            return
        }
        do {
            var next = state
            next.displayName = try leaderboardDisplayName(name)
            next.claudeBilling = claude
            next.codexBilling = codex
            try persist(next)
            state = next
            lastError = nil
            status = "Profile saved on this Mac."
        } catch { lastError = error.localizedDescription }
    }

    func enable(name: String, claude: LeaderboardBilling, codex: LeaderboardBilling) {
        enable(name: name, website: LeaderboardConfiguration.origin.absoluteString, claude: claude, codex: codex)
    }

    func enable(name: String, website: String, claude: LeaderboardBilling, codex: LeaderboardBilling) {
        guard !state.pendingRemoval else { return }
        do {
            let origin = try leaderboardOrigin(website).absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let displayName = try leaderboardDisplayName(name)
            guard claude != .unclassified || codex != .unclassified else {
                throw LeaderboardError.message("Choose a billing category for at least one tool.")
            }
            if state.enabled, origin != state.website {
                throw LeaderboardError.message("Turn off sharing and finish removal before changing websites.")
            }
            var next = state
            next.displayName = displayName
            next.website = origin
            next.claudeBilling = claude
            next.codexBilling = codex
            if next.token.isEmpty {
                var bytes = [UInt8](repeating: 0, count: 32)
                guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
                    throw LeaderboardError.message("Couldn’t create the leaderboard identity. Please try again.")
                }
                next.token = bytes.map { String(format: "%02x", $0) }.joined()
            }
            next.enabled = true
            try persist(next)
            state = next
            lastError = nil
            nextAttemptAt = max(Date(), retryNotBefore)
            status = "Ready to sync daily usage totals."
            tick()
        } catch { lastError = error.localizedDescription }
    }

    func disable() {
        guard state.enabled else { return }
        // Serialize DELETE after any in-flight PUT. Persist the intent before
        // the request so quitting or being offline cannot lose the removal.
        state.enabled = false
        state.pendingRemoval = true
        do { try persist(state); lastError = nil }
        catch { lastError = "Couldn’t save the removal request: \(error.localizedDescription)" }
        status = "Removing your profile and shared totals…"
        nextAttemptAt = max(Date(), retryNotBefore)
        tick()
    }

    func tick() {
        guard !inFlight, Date() >= nextAttemptAt else { return }
        guard state.pendingRemoval || (state.enabled && latestRecords != nil) else { return }
        inFlight = true
        Task {
            let removing = state.pendingRemoval
            do {
                let origin = try leaderboardOrigin(state.website)
                var request = URLRequest(url: origin.appendingPathComponent(removing ? "api/v1/profile" : "api/v1/snapshot"))
                request.httpMethod = removing ? "DELETE" : "PUT"
                request.timeoutInterval = 25
                request.setValue("Bearer \(state.token)", forHTTPHeaderField: "Authorization")
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue("ClaudeUsageBar/0.3", forHTTPHeaderField: "User-Agent")
                if !removing {
                    let records = latestRecords ?? []
                    let previous = state.archive
                    let archive = await Task.detached { archiveLeaderboardUsage(records, previous: previous) }.value
                    // The user can opt out while aggregation is running.
                    guard state.enabled else { inFlight = false; tick(); return }
                    state.archive = archive
                    try persist(state)
                    request.httpBody = try JSONEncoder().encode(leaderboardSnapshot(state))
                }
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else { throw LeaderboardError.message("No response from the leaderboard.") }
                guard http.statusCode == (removing ? 204 : 200) else {
                    let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                    let message = body?["error"] as? String ?? "Leaderboard returned HTTP \(http.statusCode)."
                    let retry = http.value(forHTTPHeaderField: "Retry-After").flatMap { value -> TimeInterval? in
                        if let seconds = Double(value) { return seconds }
                        let format = DateFormatter(); format.locale = Locale(identifier: "en_US_POSIX")
                        format.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
                        return format.date(from: value)?.timeIntervalSinceNow
                    }
                    throw LeaderboardError.http(message, retryAfter: retry)
                }
                failures = 0
                retryNotBefore = .distantPast
                lastError = nil
                if removing {
                    state.pendingRemoval = false
                    state.token = ""
                    state.archive = []
                    state.lastSynced = nil
                    status = "Removed from the leaderboard. Sharing is off."
                } else if state.enabled {
                    state.lastSynced = Date()
                    status = "Shared at \(clock(Date())). Syncs every 5 minutes."
                }
                try persist(state)
                nextAttemptAt = state.pendingRemoval ? .distantPast : Date().addingTimeInterval(300)
            } catch {
                failures += 1
                var delay = min(1800, 30 * pow(2, Double(min(failures, 6)))) + Double.random(in: 0...10)
                if case LeaderboardError.http(_, let retry) = error { delay = max(delay, retry ?? 0) }
                nextAttemptAt = Date().addingTimeInterval(delay)
                retryNotBefore = nextAttemptAt
                lastError = error.localizedDescription
                status = state.pendingRemoval ? "Removal pending. Retrying at \(clock(nextAttemptAt))." : "Sync paused. Retrying at \(clock(nextAttemptAt))."
            }
            inFlight = false
            if state.pendingRemoval, Date() >= nextAttemptAt { tick() }
        }
    }

    private func persist(_ value: LeaderboardState) throws {
        let folder = stateURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        try JSONEncoder().encode(value).write(to: stateURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stateURL.path)
    }
}
