// Token counts from Claude Code's own session transcripts (~/.claude/projects/**/*.jsonl).
// The usage endpoint only reports percentages, but every assistant turn in a transcript carries
// the API's `usage` block, so summing those gives input and output tokens for this Mac.
import Foundation

struct TokenRecord {
    let date: Date
    let model: String
    let input: Int
    let output: Int
    let cacheWrite: Int
    let cacheRead: Int
    /// API list-price equivalent in USD, nil when the model is not in `apiPrices`.
    let cost: Double?
}

/// Reads transcripts incrementally: files are append-only, so each pass only parses the bytes
/// added since the last one.
actor TokenScanner {
    /// How far back to keep records, a little over the longest chart range.
    static let horizon: TimeInterval = 31 * 86_400

    private var offsets: [String: UInt64] = [:]
    /// Keyed by message id + request id. One response is written as several lines (one per
    /// content block, the output count growing as it streams), and resumed sessions copy
    /// earlier lines into a new file, so the same key shows up many times. Keep the largest.
    private var records: [String: TokenRecord] = [:]
    private let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    func scan() -> [TokenRecord] {
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
        let cutoff = Date().addingTimeInterval(-Self.horizon)
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
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
        records = records.filter { $0.value.date >= cutoff }
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
              let ts = d["timestamp"] as? String, let date = iso.date(from: ts),
              let model = m["model"] as? String, model != "<synthetic>"
        else { return }
        let key = "\(m["id"] as? String ?? "")|\(d["requestId"] as? String ?? d["uuid"] as? String ?? "")"
        let input = u["input_tokens"] as? Int ?? 0
        let output = u["output_tokens"] as? Int ?? 0
        let cacheWrite = u["cache_creation_input_tokens"] as? Int ?? 0
        let cacheRead = u["cache_read_input_tokens"] as? Int ?? 0
        // The TTL split matters for cost (1-hour writes cost more); without it, assume 5-minute.
        let write1h = min(cacheWrite, (u["cache_creation"] as? [String: Any])?["ephemeral_1h_input_tokens"] as? Int ?? 0)
        let cost = apiCost(model: model, input: input, output: output, cacheWrite5m: cacheWrite - write1h,
                           cacheWrite1h: write1h, cacheRead: cacheRead, fast: u["speed"] as? String == "fast")
        let r = TokenRecord(date: date, model: model, input: input, output: output,
                            cacheWrite: cacheWrite, cacheRead: cacheRead, cost: cost)
        if let old = records[key], old.output >= r.output { return }
        records[key] = r
    }
}

@MainActor
final class TokenStore: ObservableObject {
    @Published private(set) var records: [TokenRecord] = []
    @Published private(set) var loaded = false
    private var scanning = false
    private let scanner = TokenScanner()

    func refresh() {
        guard !scanning else { return }
        scanning = true
        Task {
            records = await scanner.scan()
            loaded = true
            scanning = false
        }
    }
}

// MARK: - Aggregation

enum TokenMetric: String, CaseIterable, Identifiable {
    case cost = "API cost", input = "Input", output = "Output", cacheWrite = "Cache write", cacheRead = "Cache read"
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
}

func summarize(_ records: [TokenRecord], range: TokenRange, metric: TokenMetric, now: Date = Date()) -> TokenSummary {
    let cal = Calendar.current
    let last = cal.dateInterval(of: range.unit, for: now)!.start
    let starts = (0..<range.count).map { cal.date(byAdding: range.unit, value: $0 - range.count + 1, to: last)! }
    var perBucket: [Date: Double] = [:]
    var perModel: [String: Double] = [:]
    var s = TokenSummary()
    for r in records where r.date >= starts[0] {
        for m in TokenMetric.allCases { s.totals[m, default: 0] += m.value(r) }
        if r.cost == nil { s.unpriced.insert(modelName(r.model)) }
        let v = metric.value(r)
        perBucket[cal.dateInterval(of: range.unit, for: r.date)!.start, default: 0] += v
        perModel[modelName(r.model), default: 0] += v
    }
    s.buckets = starts.map { TokenBucket(start: $0, value: perBucket[$0] ?? 0) }
    s.byModel = perModel.filter { $0.value > 0 }.sorted { $0.value > $1.value }.map { ($0.key, $0.value) }
    return s
}

/// "claude-opus-5-5" -> "Opus 5.5", "claude-haiku-4-5-20251001" -> "Haiku 4.5".
func modelName(_ id: String) -> String {
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
