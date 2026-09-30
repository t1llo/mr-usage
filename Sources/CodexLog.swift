// Token counts and rate limits from Codex CLI's session logs ($CODEX_HOME/sessions/**/rollout-*.jsonl,
// ~/.codex by default). Every line is {"timestamp", "type", "payload"}. The lines that matter:
//   session_meta        once per file, carries the thread id
//   turn_context        once per user turn, carries the model
//   token_usage_record  one per API response (Codex 0.153 and later)
//   event_msg/token_count  running totals plus the latest rate-limit snapshot
import Foundation

/// ChatGPT plan limits, fetched live or taken from the newest snapshot in Codex's logs. Codex
/// only logs them from response headers, so a logged one is as old as the last Codex request.
struct CodexLimits {
    let asOf: Date
    let usage: Usage
    let plan: String?
    let live: Bool
    let credits: CodexCredits?

    var hasData: Bool { !usage.limits.isEmpty || credits != nil }
}

actor CodexScanner {
    /// Per-file parse state, kept between passes because files are read incrementally.
    private struct FileState {
        var offset: UInt64 = 0
        var thread: String?
        /// Set for forked threads; lines before it were copied from the parent.
        var forkedAt: Date?
        var model: String?
        var turnModels: [String: String] = [:]
        /// Last token_count total, to tell a new response from a repeated or rewritten total.
        var prevTotal = Tokens()
        /// Once a file has per-response records, its token_count lines are only used for limits.
        var sawRecord = false
    }

    /// OpenAI convention: `input` includes cached and cache-write tokens, `output` includes
    /// reasoning (`reasoning` is the part of it spent thinking, which grows with the effort).
    private struct Tokens: Equatable {
        var input = 0, cached = 0, cacheWrite = 0, output = 0, reasoning = 0, total = 0
        init() {}
        init(_ d: [String: Any]?) {
            input = d?["input_tokens"] as? Int ?? 0
            cached = d?["cached_input_tokens"] as? Int ?? 0
            cacheWrite = d?["cache_write_input_tokens"] as? Int ?? 0
            output = d?["output_tokens"] as? Int ?? 0
            reasoning = d?["reasoning_output_tokens"] as? Int ?? 0
            total = d?["total_tokens"] as? Int ?? 0
        }
        static func + (a: Tokens, b: Tokens) -> Tokens {
            var r = Tokens()
            r.input = a.input + b.input; r.cached = a.cached + b.cached; r.cacheWrite = a.cacheWrite + b.cacheWrite
            r.output = a.output + b.output; r.reasoning = a.reasoning + b.reasoning; r.total = a.total + b.total
            return r
        }
    }

    private var files: [String: FileState] = [:]
    /// Keyed by response id, or by timestamp and totals for older logs. Forks copy lines into the
    /// child's file, so the same key can appear in several files.
    private var records: [String: TokenRecord] = [:]
    private var limits: (date: Date, json: [String: Any])?
    private var creditBalance: CodexCredits?
    private let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static var home: URL {
        if let h = ProcessInfo.processInfo.environment["CODEX_HOME"], !h.isEmpty { return URL(fileURLWithPath: h) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
    }

    /// Records inside the horizon, the latest snapshot, and whether Codex has any logs at all.
    func scan() -> (records: [TokenRecord], limits: CodexLimits?, found: Bool) {
        let cutoff = Date().addingTimeInterval(-TokenScanner.horizon)
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        var found = false
        for dir in ["sessions", "archived_sessions"] {
            // Compressed (.jsonl.zst) logs are skipped: Codex only compresses logs untouched for a
            // week, and only with an experimental feature turned on.
            guard let e = FileManager.default.enumerator(at: Self.home.appendingPathComponent(dir),
                                                         includingPropertiesForKeys: keys) else { continue }
            for case let url as URL in e where url.pathExtension == "jsonl" {
                found = true
                guard let v = try? url.resourceValues(forKeys: Set(keys)),
                      let mtime = v.contentModificationDate, mtime >= cutoff,
                      let size = v.fileSize.map(UInt64.init) else { continue }
                var st = files[url.path] ?? FileState()
                if size < st.offset { st = FileState() }  // rewritten
                if size > st.offset { st.offset += read(url, state: &st) }
                files[url.path] = st
            }
        }
        records = records.filter { $0.value.date >= cutoff }
        return (Array(records.values), limits.flatMap {
            parseCodexLogLimits($0.json, asOf: $0.date, lastCredits: creditBalance)
        }, found)
    }

    private func read(_ url: URL, state st: inout FileState) -> UInt64 {
        guard let h = try? FileHandle(forReadingFrom: url) else { return 0 }
        defer { try? h.close() }
        guard (try? h.seek(toOffset: st.offset)) != nil, let data = try? h.readToEnd(),
              let end = data.lastIndex(of: 0x0A) else { return 0 }
        let needles = ["\"token_usage_record\"", "\"token_count\"", "\"turn_context\"", "\"session_meta\""]
            .map { Data($0.utf8) }
        var lineStart = data.startIndex
        while lineStart <= end {
            let lineEnd = data[lineStart...end].firstIndex(of: 0x0A)!
            let line = data[lineStart..<lineEnd]
            lineStart = lineEnd + 1
            // The type tags come first on the line; most lines are prompts and tool output, and
            // skipping them here saves parsing megabytes of JSON.
            let head = line.prefix(200)
            guard needles.contains(where: { head.range(of: $0) != nil }) else { continue }
            add(line, &st)
        }
        return UInt64(end - data.startIndex + 1)
    }

    private func add(_ line: Data, _ st: inout FileState) {
        guard let d = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let type = d["type"] as? String, let p = d["payload"] as? [String: Any],
              let ts = d["timestamp"] as? String, let date = iso.date(from: ts) else { return }
        switch type {
        case "session_meta":
            guard st.thread == nil else { return }
            st.thread = p["id"] as? String
            if p["forked_from_id"] != nil { st.forkedAt = date }
        case "turn_context":
            guard let model = p["model"] as? String else { return }
            st.model = model
            if let turn = p["turn_id"] as? String { st.turnModels[turn] = model }
        case "token_usage_record":
            st.sawRecord = true
            // A fork's copy of its parent's records belongs to the parent thread.
            guard let id = p["response_id"] as? String,
                  st.thread == nil || p["thread_id"] as? String == st.thread else { return }
            let model = (p["turn_id"] as? String).flatMap { st.turnModels[$0] } ?? st.model
            put("r|\(id)", date: date, model: model, Tokens(p["usage"] as? [String: Any]))
        case "event_msg" where p["type"] as? String == "token_count":
            if let rl = p["rate_limits"] as? [String: Any] {
                // Other buckets (per-model or "codex_other") share the event; the plan's is "codex".
                let id = rl["limit_id"] as? String
                if id == nil || id == "codex" {
                    if date >= (limits?.date ?? .distantPast) { limits = (date, rl) }
                    if date >= (creditBalance?.asOf ?? .distantPast),
                       let credits = parseCodexCredits(rl["credits"], asOf: date, live: false) {
                        creditBalance = credits
                    }
                }
            }
            guard let info = p["info"] as? [String: Any] else { return }
            let total = Tokens(info["total_token_usage"] as? [String: Any])
            let last = Tokens(info["last_token_usage"] as? [String: Any])
            defer { st.prevTotal = total }
            // Older logs only have running totals. Count `last` when it is exactly what moved the
            // total; that skips limit-only repeats, post-compaction estimates and resets.
            guard !st.sawRecord, total == st.prevTotal + last, last.total > 0,
                  date >= st.forkedAt ?? .distantPast else { return }
            put("t|\(ts)|\(total.total)|\(last.total)", date: date, model: st.model, last)
        default:
            return
        }
    }

    private func put(_ key: String, date: Date, model: String?, _ u: Tokens) {
        let model = model ?? "unknown"
        let input = max(0, u.input - u.cached - u.cacheWrite)
        // Reasoning bills as output at every effort. Codex copies the API's output_tokens, which
        // already includes it; only when the total says it was left out is it added back.
        let output = u.reasoning > 0 && u.total == u.input + u.output + u.reasoning ? u.output + u.reasoning : u.output
        records[key] = TokenRecord(
            date: date, model: model, provider: .openai, source: .codex,
            input: input, output: output, cacheWrite: u.cacheWrite, cacheRead: u.cached,
            cost: openAICost(model: model, input: input, output: output, cacheWrite: u.cacheWrite, cacheRead: u.cached))
    }
}

func parseCodexLogLimits(_ json: [String: Any], asOf: Date, lastCredits: CodexCredits? = nil) -> CodexLimits? {
    var usage = Usage()
    for key in ["primary", "secondary"] {
        guard let w = json[key] as? [String: Any], let pct = w["used_percent"] as? Double else { continue }
        let minutes = w["window_minutes"] as? Int
        let reset = (w["resets_at"] as? Double).map { Date(timeIntervalSince1970: $0) }
        usage.limits.append(Limit(id: "codex_\(key)", label: windowLabel(minutes), pct: pct,
                                  resetsAt: reset, window: minutes.map { TimeInterval($0 * 60) }))
    }
    let limits = CodexLimits(asOf: asOf, usage: usage, plan: json["plan_type"] as? String, live: false,
                             credits: parseCodexCredits(json["credits"], asOf: asOf, live: false) ?? lastCredits)
    return limits.hasData ? limits : nil
}

/// Codex's windows are set by the server; name them by length the way Codex's own TUI does.
func windowLabel(_ minutes: Int?) -> String {
    switch minutes ?? 0 {
    case 0: return "Limit"
    case ..<360: return "Session"
    case 1380...1500: return "Day"
    case 10000...10200: return "Week"
    case 43000...45000: return "Month"
    case let m where m % 1440 == 0: return "\(m / 1440) days"
    case let m: return "\(m / 60) hours"
    }
}

extension CodexLimits {
    /// Codex has not run since a window reset, so the logged percentage is stale: show it as
    /// empty with no reset time, the way the window really is now.
    func current(now: Date) -> Usage {
        var u = usage
        u.limits = u.limits.map { l in
            guard let r = l.resetsAt, r <= now else { return l }
            return Limit(id: l.id, label: l.label, pct: 0, resetsAt: nil, window: l.window)
        }
        return u
    }
}
