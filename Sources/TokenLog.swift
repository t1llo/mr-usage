// Token counts from the local logs of each coding tool: Claude Code's transcripts
// (~/.claude/projects/**/*.jsonl) here, Codex in CodexLog.swift, OpenCode in OpenCodeLog.swift.
// The usage endpoints only report percentages, but every model call in those logs carries the
// API's token counts, so summing them gives input and output tokens for this Mac.
import Foundation

enum Provider: String, CaseIterable, Identifiable {
    case claude = "Claude", openai = "OpenAI"
    var id: String { rawValue }
}

enum Source: String {
    case claudeCode = "Claude Code", codex = "Codex", opencode = "OpenCode", pi = "Pi"
    /// Daily totals from the ChatGPT account, split into token kinds by estimate.
    case chatgpt = "ChatGPT account"
}

struct TokenRecord {
    let date: Date
    let model: String
    let provider: Provider
    let source: Source
    /// Uncached input. Cache writes and reads are counted separately, for every provider.
    let input: Int
    let output: Int
    let cacheWrite: Int
    let cacheRead: Int
    /// API list-price equivalent in USD, nil when the model is not in `apiPrices`.
    let cost: Double?
    /// Part of cacheWrite, retained separately for the leaderboard's pricing.
    var cacheWrite1h: Int = 0
}

/// Publish both sources together after the initial scan and account fetch have finished.
struct TokenSnapshot {
    let local: [TokenRecord]
    var account: [TokenRecord] = []
}

/// Reads transcripts incrementally: files are append-only, so each pass only parses the bytes
/// added since the last one.
actor TokenScanner {
    /// How far back to keep records, a little over the longest chart range.
    static let horizon: TimeInterval = 31 * 86_400

    private var offsets: [String: UInt64] = [:]
    /// Keyed by API message id. One response is written as several lines (one per
    /// content block, the output count growing as it streams), and resumed sessions copy
    /// earlier lines into a new file, so the same key shows up many times. Keep the largest.
    private var records: [String: TokenRecord] = [:]
    private var fastResponses: Set<String> = []
    private let root: URL?
    init(root: URL? = nil) {
        self.root = root
    }
    private let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    func scan() -> [TokenRecord] {
        let cutoff = Date().addingTimeInterval(-Self.horizon)
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        for root in root.map({ [$0] }) ?? ClaudePaths.transcriptRoots {
            if let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys) {
                for case let url as URL in files where url.pathExtension == "jsonl" {
                    guard let v = try? url.resourceValues(forKeys: Set(keys)),
                          let mtime = v.contentModificationDate, mtime >= cutoff,
                          let size = v.fileSize.map(UInt64.init) else { continue }
                    var start = offsets[url.path] ?? 0
                    if size < start { start = 0 }  // rewritten or truncated
                    if size > start { offsets[url.path] = start + read(url, from: start) }
                }
            }
        }
        records = records.filter { $0.value.date >= cutoff }
        fastResponses = fastResponses.intersection(records.keys)
        return Array(records.values)
    }

    /// Parses complete lines from `offset` on and returns how many bytes it consumed. A final
    /// line without a newline may still be being written, so it is left for the next pass.
    private func read(_ url: URL, from offset: UInt64) -> UInt64 {
        guard let h = try? FileHandle(forReadingFrom: url) else { return 0 }
        defer { try? h.close() }
        guard (try? h.seek(toOffset: offset)) != nil, let data = try? h.readToEnd(),
              let end = data.lastIndex(of: 0x0A) else { return 0 }
        let needle = Data("\"usage\"".utf8)
        var lineStart = data.startIndex
        while lineStart <= end {
            let lineEnd = data[lineStart...end].firstIndex(of: 0x0A)!
            let line = data[lineStart..<lineEnd]
            lineStart = lineEnd + 1
            // Most lines are user turns and tool results; skip them before paying for JSON.
            guard line.range(of: needle) != nil else { continue }
            add(line)
        }
        return UInt64(end - data.startIndex + 1)
    }

    private func add(_ line: Data) {
        guard let d = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              d["type"] as? String == "assistant",
              let m = d["message"] as? [String: Any],
              let u = m["usage"] as? [String: Any],
              let ts = d["timestamp"] as? String, let date = iso.date(from: ts) ?? isoDate(ts),
              let model = m["model"] as? String, model != "<synthetic>"
        else { return }
        // Content blocks have different transcript UUIDs, even when requestId is absent.
        // The API message id identifies the response across blocks and resumed copies.
        guard let key = m["id"] as? String ?? d["requestId"] as? String ?? d["uuid"] as? String,
              !key.isEmpty else { return }
        let old = records[key]
        let input = max(old?.input ?? 0, max(0, u["input_tokens"] as? Int ?? 0))
        let output = max(old?.output ?? 0, max(0, u["output_tokens"] as? Int ?? 0))
        let cacheWrite = max(old?.cacheWrite ?? 0, max(0, u["cache_creation_input_tokens"] as? Int ?? 0))
        let cacheRead = max(old?.cacheRead ?? 0, max(0, u["cache_read_input_tokens"] as? Int ?? 0))
        // The TTL split matters for cost (1-hour writes cost more); without it, assume 5-minute.
        let write1h = min(cacheWrite, max(old?.cacheWrite1h ?? 0,
            max(0, (u["cache_creation"] as? [String: Any])?["ephemeral_1h_input_tokens"] as? Int ?? 0)))
        if u["speed"] as? String == "fast" { fastResponses.insert(key) }
        let cost = apiCost(model: model, input: input, output: output, cacheWrite5m: cacheWrite - write1h,
                           cacheWrite1h: write1h, cacheRead: cacheRead, fast: fastResponses.contains(key))
        let r = TokenRecord(date: min(old?.date ?? date, date), model: model, provider: .claude, source: .claudeCode, input: input, output: output,
                            cacheWrite: cacheWrite, cacheRead: cacheRead, cost: cost, cacheWrite1h: write1h)
        records[key] = r
    }
}

@MainActor
final class TokenStore: ObservableObject {
    @Published private(set) var records: [TokenRecord] = [] { didSet { rebuildAccount() } }
    /// The live ChatGPT limits when the fetch works, else the newest logged snapshot.
    var codexLimits: CodexLimits? {
        guard let live = liveLimits else { return loggedLimits }
        return (loggedLimits?.asOf ?? .distantPast) > live.asOf ? loggedLimits : live
    }
    /// A rate-limit snapshot can omit credits; use the newest balance that is actually present.
    var codexCredits: CodexCredits? {
        [liveCredits, loggedLimits?.credits].compactMap { $0 }.max { $0.asOf < $1.asOf }
    }
    @Published private var liveCredits: CodexCredits?
    @Published private(set) var liveLimits: CodexLimits?
    @Published private(set) var loggedLimits: CodexLimits?
    /// Why the live fetch is not working, shown under the limits. Nil when it works or when
    /// Codex is not signed in with ChatGPT at all.
    @Published private(set) var liveError: String?
    /// Past windows of the ChatGPT plan, from the endpoint behind Codex's /usage.
    @Published private(set) var planHistory: PlanHistory?
    /// Lifetime and daily tokens across every Codex surface, the overview in Codex's /usage.
    @Published private(set) var activity: AccountActivity? { didSet { rebuildAccount() } }
    /// Claude Code's local, lifetime stats cache, never added to the recent log records.
    @Published private(set) var claudeActivity: ClaudeActivity?
    /// Account estimates plus local usage on UTC days the account has not reported yet.
    private(set) var accountRecords: [TokenRecord] = []
    private var estimatedAccountRecords: [TokenRecord] = []
    @Published private(set) var sharingSnapshot: TokenSnapshot?
    private var checkedAccount = false
    /// Whether the estimated split of `accountRecords` comes from this Mac's OpenAI logs.
    private(set) var mixFromLogs = false
    /// Summaries are asked for on every redraw (hover, provider switch), and a 30-day one over
    /// thousands of records takes a frame's worth of time, so each is computed once per data change.
    @Published private var summaries: [SummaryKey: TokenSummary] = [:]
    private var aggregationGeneration = 0
    private var aggregating = false
    private(set) var providerSources: [Provider: Set<Source>] = [:]
    private struct SummaryKey: Hashable {
        let provider: Provider, account: Bool, range: TokenRange, metric: TokenMetric
    }
    private var nextHistoryAt = Date.distantPast
    private var liveInterval: TimeInterval = 120
    private var nextLiveAt = Date.distantPast
    private var fetchingLive = false
    @Published private(set) var checkingLive = false
    /// Tools that have logs on this Mac, even if nothing falls inside the chart range.
    @Published private(set) var sources: Set<Source> = []
    @Published private(set) var loaded = false
    private var scanned = false
    private var scanning = false
    private var nextScanAt = Date.distantPast
    private let claude = TokenScanner()
    private let codex = CodexScanner()
    private let opencode = OpenCodeReader()
    private let pi = PiScanner()

    init() {
        refresh()
        // Codex limits drive the menu bar title when OpenAI is selected, so keep reading its
        // logs while the panel is closed. Each pass only parses bytes added since the last one.
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        fetchLive()
        guard !scanning, Date() >= nextScanAt else { return }
        scanning = true
        nextScanAt = Date().addingTimeInterval(60)
        Task {
            async let a = claude.scan()
            async let b = codex.scan()
            async let c = opencode.scan()
            async let d = pi.scan()
            async let stats = Task.detached { readClaudeActivity(directory: ClaudePaths.directory()) }.value
            let (cl, cx, oc, piRecords, lifetime) = await (a, b, c, d, stats)
            records = cl + cx.records + oc.records + piRecords
            claudeActivity = lifetime
            loggedLimits = cx.limits
            var s = Set<Source>()
            if !cl.isEmpty { s.insert(.claudeCode) }
            if cx.found { s.insert(.codex) }
            if oc.found { s.insert(.opencode) }
            if !piRecords.isEmpty { s.insert(.pi) }
            sources = s
            scanned = true
            publishSnapshot()
            scanning = false
        }
    }

    /// Every two minutes at most, doubling up to ten after a 429 or 5xx, like the Claude poll.
    private func fetchLive() {
        guard !fetchingLive, Date() >= nextLiveAt else { return }
        fetchingLive = true
        checkingLive = true
        nextLiveAt = Date().addingTimeInterval(liveInterval)
        Task {
            defer { fetchingLive = false; checkingLive = false; checkedAccount = true; publishSnapshot() }
            do {
                guard let auth = try await Task.detached(operation: readCodexAuth).value else {
                    liveError = liveLimits == nil ? nil : "ChatGPT login unavailable"
                    return
                }
                // Start limits immediately; optional history must not delay their display.
                async let limitResult = fetchCodexLimits(auth)
                async let history: PlanHistory? = Date() >= nextHistoryAt ? try? fetchPlanHistory(auth) : nil
                async let account: AccountActivity? = Date() >= nextHistoryAt ? try? fetchAccountActivity(auth) : nil
                let live = try await limitResult
                if let credits = live.credits { liveCredits = credits }
                if live.hasData { liveLimits = live }
                liveError = live.hasData ? nil : "no limits or credits for this account"
                // Both are aggregated daily on the server, so every ten minutes is plenty.
                if Date() >= nextHistoryAt {
                    let (h, a) = await (history, account)
                    if let h { planHistory = h.periods.isEmpty ? nil : h }
                    if let a { activity = a }
                    if h != nil || a != nil { nextHistoryAt = Date().addingTimeInterval(600) }
                }
            } catch {
                liveError = error.localizedDescription
                if let fe = error as? FetchError, fe.isTransient {
                    liveInterval = min(liveInterval * 2, 600)
                    nextLiveAt = Date().addingTimeInterval(max(liveInterval, fe.retryAfter ?? 0))
                }
            }
        }
    }
}

extension TokenStore {
    func summary(_ provider: Provider, account: Bool, range: TokenRange, metric: TokenMetric) -> TokenSummary {
        summaries[SummaryKey(provider: provider, account: account, range: range, metric: metric)] ?? TokenSummary()
    }

    private func rebuildAccount() {
        aggregationGeneration += 1
        guard !aggregating else { return }
        aggregating = true
        Task {
            // Coalesce scans and account responses arriving during an aggregation.
            while true {
                let generation = aggregationGeneration
                let records = records, activity = activity
                let result = await Task.detached(priority: .utility) {
                    let local = TokenMix(records.filter { $0.provider == .openai })
                    let estimated = activity.map { estimatedRecords($0, mix: local ?? .codex) } ?? []
                    let account = reconciledOpenAIRecords(local: records, account: estimated)
                    var summaries: [SummaryKey: TokenSummary] = [:]
                    let now = Date()
                    for provider in Provider.allCases {
                        for useAccount in [false, true] where !useAccount || provider == .openai {
                            for range in TokenRange.allCases {
                                let batch = summarizeMetrics(useAccount ? account : records, provider: provider, range: range,
                                                             now: now, calendar: useAccount ? usageUTCCalendar : .current)
                                for (metric, summary) in batch {
                                    summaries[SummaryKey(provider: provider, account: useAccount, range: range, metric: metric)] = summary
                                }
                            }
                        }
                    }
                    let sources = Dictionary(grouping: records, by: \.provider).mapValues { Set($0.map(\.source)) }
                    return (estimated, account, summaries, sources, local != nil)
                }.value
                guard generation == aggregationGeneration else { continue }
                estimatedAccountRecords = result.0
                accountRecords = result.1
                providerSources = result.3
                mixFromLogs = result.4
                aggregating = false
                loaded = scanned
                summaries = result.2
                publishSnapshot()
                break
            }
        }
    }

    private func publishSnapshot() {
        guard loaded && checkedAccount && !aggregating else { return }
        sharingSnapshot = TokenSnapshot(local: records, account: estimatedAccountRecords)
    }
}

// MARK: - Aggregation

enum TokenMetric: String, CaseIterable, Identifiable {
    case cost = "API cost", input = "Input", output = "Output", cacheWrite = "Cache write", cacheRead = "Cache read"
    var label: String { self == .input ? "Uncached input" : rawValue }
    var id: String { rawValue }
    static let tokenKinds: [TokenMetric] = [.input, .output, .cacheWrite, .cacheRead]

    func value(_ r: TokenRecord) -> Double {
        switch self {
        case .cost: return r.cost ?? 0
        case .input: return Double(r.input)
        case .output: return Double(r.output)
        case .cacheWrite: return Double(r.cacheWrite)
        case .cacheRead: return Double(r.cacheRead)
        }
    }

    /// "$1,234", "$12.34" for cost; "4.56M" for tokens.
    func format(_ v: Double) -> String {
        guard self == .cost else { return compact(v) }
        if v >= 1000 {
            let f = NumberFormatter(); f.numberStyle = .decimal; f.maximumFractionDigits = 0
            return "$" + (f.string(from: NSNumber(value: v)) ?? "\(Int(v))")
        }
        return String(format: "$%.2f", v)
    }
}

enum TokenRange: String, CaseIterable, Identifiable {
    case day = "24h", week = "7d", month = "30d"
    var id: String { rawValue }
    var unit: Calendar.Component { self == .day ? .hour : .day }
    var count: Int { self == .day ? 24 : self == .week ? 7 : 30 }
}

struct TokenBucket: Identifiable {
    let start: Date
    let value: Double
    var id: Date { start }
}

struct TokenSummary {
    var buckets: [TokenBucket] = []
    var totals: [TokenMetric: Double] = [:]
    /// Selected metric per model, largest first.
    var byModel: [(name: String, value: Double)] = []
    /// Models in range that have no API price, so their tokens are missing from the cost.
    var unpriced: Set<String> = []
    /// All token kinds, not just new input. Cache reads often dominate Claude totals.
    var totalTokens: Double { TokenMetric.tokenKinds.reduce(0) { $0 + (totals[$1] ?? 0) } }
}

func summarize(_ records: [TokenRecord], provider: Provider, range: TokenRange, metric: TokenMetric,
               now: Date = Date(), calendar cal: Calendar = .current) -> TokenSummary {
    summarizeMetrics(records, provider: provider, range: range, now: now, calendar: cal)[metric] ?? TokenSummary()
}

/// Share filtering, model names and bucket lookup across all five chart metrics.
func summarizeMetrics(_ records: [TokenRecord], provider: Provider, range: TokenRange,
                      now: Date = Date(), calendar cal: Calendar = .current) -> [TokenMetric: TokenSummary] {
    let last = cal.dateInterval(of: range.unit, for: now)!.start
    let starts = (0..<range.count).map { cal.date(byAdding: range.unit, value: $0 - range.count + 1, to: last)! }
    let inRange = records.filter { $0.provider == provider && $0.date >= starts[0] && $0.date <= now }
    let tagged = Set(inRange.map(\.source)).count > 1
    let metrics = TokenMetric.allCases
    var totals: [TokenMetric: Double] = [:]
    var buckets = Array(repeating: Array(repeating: 0.0, count: starts.count), count: metrics.count)
    var models = Array(repeating: [String: Double](), count: metrics.count)
    var names: [String: String] = [:]
    var unpriced: Set<String> = []
    for r in inRange {
        let name = names[r.model] ?? modelName(r.model)
        names[r.model] = name
        if r.cost == nil { unpriced.insert(name) }
        let label = name + (tagged ? " · \(r.source.rawValue)" : "")
        let bucket = bucketIndex(r.date, in: starts)
        for (index, metric) in metrics.enumerated() {
            let value = metric.value(r)
            totals[metric, default: 0] += value
            buckets[index][bucket] += value
            models[index][label, default: 0] += value
        }
    }
    var result: [TokenMetric: TokenSummary] = [:]
    for (index, metric) in metrics.enumerated() {
        result[metric] = TokenSummary(
            buckets: starts.enumerated().map { TokenBucket(start: $0.element, value: buckets[index][$0.offset]) },
            totals: totals,
            byModel: models[index].filter { $0.value > 0 }.sorted { $0.value > $1.value }.map { ($0.key, $0.value) },
            unpriced: unpriced)
    }
    return result
}

/// The last bucket start at or before `date`, by binary search: far cheaper per record than
/// asking the calendar, and exact across DST changes because `starts` came from the calendar.
private func bucketIndex(_ date: Date, in starts: [Date]) -> Int {
    var lo = 0, hi = starts.count - 1
    while lo < hi {
        let mid = (lo + hi + 1) / 2
        if starts[mid] <= date { lo = mid } else { hi = mid - 1 }
    }
    return lo
}

/// "claude-opus-5-5" -> "Opus 5.5", "claude-haiku-4-5-20251001" -> "Haiku 4.5",
/// "gpt-6-sol" -> "GPT-6 Sol", "gpt-5.3-codex" -> "GPT-5.3 Codex".
func modelName(_ id: String) -> String {
    if id.hasPrefix("gpt-") {
        let parts = id.dropFirst(4).split(separator: "-").map(String.init)
        guard let version = parts.first else { return id }
        return (["GPT-" + version] + parts.dropFirst().map { $0.prefix(1).uppercased() + $0.dropFirst() })
            .joined(separator: " ")
    }
    var parts = id.split(separator: "-").map(String.init)
    if parts.first == "claude" { parts.removeFirst() }
    if let l = parts.last, l.count == 8, Int(l) != nil { parts.removeLast() }
    guard let family = parts.first else { return id }
    let version = parts.dropFirst().joined(separator: ".")
    return family.prefix(1).uppercased() + family.dropFirst() + (version.isEmpty ? "" : " " + version)
}

/// 950, 12.3K, 4.56M, 1.2B.
func compact(_ d: Double) -> String {
    if d >= 1e9 { return String(format: "%.1fB", d / 1e9) }
    if d >= 1e6 { return String(format: d >= 1e8 ? "%.0fM" : "%.2fM", d / 1e6) }
    if d >= 1e3 { return String(format: d >= 1e5 ? "%.0fK" : "%.1fK", d / 1e3) }
    return String(Int(d))
}
