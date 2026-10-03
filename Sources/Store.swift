// Polling state. Same schedule as before: every minute, doubling up to 10 minutes after a 429
// or 5xx, never faster than the server's Retry-After, and menu opens cannot bypass it.
import Foundation

@MainActor
final class Store: ObservableObject {
    @Published private(set) var usage: Usage?
    @Published private(set) var lastGoodAt: Date?
    @Published var lastError: String?
    @Published private(set) var inFlight = false
    @Published private(set) var loginSource: ClaudeLoginSource
    @Published private(set) var authLabel: String?
    var configDirectory: URL { ClaudePaths.directory(defaults: defaults) }

    private let defaults: UserDefaults
    private var polling: ClaudePollingState
    var nextFetchAt: Date { polling.nextFetchAt }
    /// Claude Code rewrites the Keychain item when it refreshes the token. A read that lands in
    /// that window finds nothing, so remember the last token we saw and fall back to it.
    private var cachedToken: String?
    private let readAuth: @Sendable (ClaudeLoginSource, URL) -> ClaudeAuth?
    private let fetchLimits: @Sendable (String) async throws -> Usage
    private let currentDate: @Sendable () -> Date

    init(defaults: UserDefaults = .standard, startPolling: Bool = true,
         readAuth: @escaping @Sendable (ClaudeLoginSource, URL) -> ClaudeAuth? = { readClaudeAuth(source: $0, directory: $1) },
         fetchLimits: @escaping @Sendable (String) async throws -> Usage = { try await fetchUsage(token: $0) },
         currentDate: @escaping @Sendable () -> Date = { Date() }) {
        self.defaults = defaults
        self.readAuth = readAuth
        self.fetchLimits = fetchLimits
        self.currentDate = currentDate
        loginSource = defaults.string(forKey: "claudeLoginSource").flatMap(ClaudeLoginSource.init(rawValue:)) ?? .automatic
        polling = ClaudePollingState.load(from: defaults)
        usage = polling.usage
        lastGoodAt = polling.lastGoodAt
        lastError = polling.lastFailure
        authLabel = polling.authLabel
        guard startPolling else { return }
        tick()
        Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    /// Fetch if the schedule says so. The timer, panel opens and the Refresh button all go
    /// through here, so none of them can exceed the current cadence.
    func tick() { if currentDate() >= nextFetchAt { fetch() } }

    func setLoginSource(_ source: ClaudeLoginSource) {
        guard !inFlight, source != loginSource else { return }
        loginSource = source
        defaults.set(source.rawValue, forKey: "claudeLoginSource")
        clearSelectedLogin()
    }

    func setConfigDirectory(_ directory: URL) {
        guard !inFlight else { return }
        defaults.set(directory.standardizedFileURL.path, forKey: ClaudePaths.directoryPreference)
        loginSource = .claudeCode
        defaults.set(loginSource.rawValue, forKey: "claudeLoginSource")
        clearSelectedLogin()
    }

    private func clearSelectedLogin() {
        cachedToken = nil
        polling.clearReading()
        usage = nil; lastGoodAt = nil; lastError = nil; authLabel = nil
        polling.save(to: defaults)
        tick()
    }

    /// Preserve older readings internally, but never present hours-old or expired windows
    /// as current percentages. Expired windows are unknown, not an invented zero.
    func displayUsage(now: Date? = nil) -> Usage? {
        let now = now ?? currentDate()
        guard var usage, let at = lastGoodAt, now.timeIntervalSince(at) <= 3600 else { return nil }
        usage.limits = usage.limits.filter { $0.resetsAt.map { $0 > now } ?? true }
        return usage.limits.isEmpty && usage.credits == nil ? nil : usage
    }

    private func fetch() {
        guard !inFlight, polling.begin(at: currentDate()) else { return }
        inFlight = true
        // Save the request gate before starting, so quitting/relaunching cannot bypass it.
        polling.save(to: defaults)
        Task {
            defer { polling.save(to: defaults); inFlight = false }
            do {
                // Pin Automatic to its resolved tool after a successful read. A temporary
                // Keychain failure must not silently select someone else's OpenCode/Pi login.
                let source = loginSource == .automatic ? polling.authSource ?? .automatic : loginSource
                let directory = configDirectory, reader = readAuth
                if let auth = await Task.detached(operation: { reader(source, directory) }).value {
                    if !auth.hasAccountMetadata, cachedToken != auth.token {
                        // These tools don't report account IDs. A replaced access token could
                        // mean either refresh or account switch: don't reuse its old limits,
                        // including across launches where there is no cached token to compare.
                        polling.clearReading()
                    }
                    polling.selectIdentity(auth)
                    usage = polling.usage; lastGoodAt = polling.lastGoodAt
                    authLabel = auth.label
                    cachedToken = auth.token
                }
                guard let token = cachedToken else { throw FetchError.noToken }
                let fresh = try await fetchLimits(token)
                polling.succeeded(fresh, at: currentDate())
                usage = fresh
                lastGoodAt = polling.lastGoodAt
                lastError = nil
            } catch {
                if case FetchError.http(401, _, _) = error { cachedToken = nil }
                lastError = error.localizedDescription
                polling.failed(error, at: currentDate())
            }
        }
    }

    var status: String {
        var s: String
        if inFlight { s = "Refreshing…" }
        else if lastError == "rate limited" {
            s = "Anthropic’s usage endpoint is throttling checks (HTTP 429). This is not your session or weekly limit."
            if let at = lastGoodAt { s += displayUsage() == nil ? " Last successful check: \(resetClock(at)); current limits unknown." : " Showing saved limits from \(resetClock(at))." }
        }
        else if let e = lastError, let at = lastGoodAt { s = "Couldn't refresh: \(e). Last successful check: \(resetClock(at))." }
        else if let e = lastError { s = "Couldn't load usage: \(e)." }
        else if let at = lastGoodAt, displayUsage() == nil { s = "Current limits are unknown. Last successful check: \(resetClock(at))." }
        else if let at = lastGoodAt { s = "Updated \(clock(at))" }
        else { s = "Loading…" }
        if lastError != nil, !inFlight {
            if let at = polling.lastAttemptAt { s += " Last attempt: \(dayClockForStatus(at))." }
            s += " Next automatic check: \(resetClock(nextFetchAt))."
        }
        else if usage == nil, !inFlight, currentDate() < nextFetchAt { s += " Waiting for the saved request cooldown until \(resetClock(nextFetchAt))." }
        return s
    }

    private func dayClockForStatus(_ date: Date) -> String {
        Calendar.current.isDateInToday(date) ? clock(date) : resetClock(date)
    }
}
