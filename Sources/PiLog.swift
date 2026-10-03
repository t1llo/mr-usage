import Foundation
import CryptoKit

/// Pi session trees can branch, fork into copied files, or be rewritten. Reread the recent
/// horizon and deduplicate identical assistant messages across forks; count all real calls,
/// including branches no longer on the active path. Never count compaction's tokensBefore.
actor PiScanner {
    private let root: URL?
    init(root: URL? = nil) { self.root = root }

    func scan() -> [TokenRecord] {
        let cutoff = Date().addingTimeInterval(-TokenScanner.horizon)
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let files = FileManager.default.enumerator(at: root ?? piAgentDirectory.appendingPathComponent("sessions"),
                                                        includingPropertiesForKeys: keys) else { return [] }
        var records: [String: TokenRecord] = [:]
        for case let url as URL in files where url.pathExtension == "jsonl" {
            guard let modified = try? url.resourceValues(forKeys: Set(keys)).contentModificationDate,
                  modified >= cutoff, let data = try? Data(contentsOf: url),
                  let end = data.lastIndex(of: 0x0A) else { continue }
            // Ignore incomplete final lines, even if they happen to be parseable JSON.
            for line in data[..<end].split(separator: 0x0A) {
                guard let entry = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                      entry["type"] as? String == "message",
                      let message = entry["message"] as? [String: Any], message["role"] as? String == "assistant",
                      let usage = message["usage"] as? [String: Any],
                      let model = message["model"] as? String,
                      let providerID = message["provider"] as? String else { continue }
                let provider: Provider
                switch providerID {
                case "anthropic": provider = .claude
                case "openai", "openai-codex": provider = .openai
                default: continue // Bedrock, proxies and unrelated providers are not subscription accounts.
                }
                let date = usageNumber(message["timestamp"]).map { Date(timeIntervalSince1970: $0 / 1000) }
                    ?? isoDate(entry["timestamp"])
                guard let date, date >= cutoff, date <= Date(),
                      let fingerprint = try? JSONSerialization.data(withJSONObject: message, options: [.sortedKeys]) else { continue }
                func count(_ key: String) -> Int {
                    guard let n = usageNumber(usage[key]), n.isFinite, n >= 0, n < Double(Int.max) else { return 0 }
                    return Int(n)
                }
                // Pi normalizes input to uncached tokens, and output already includes reasoning.
                let input = count("input"), output = count("output")
                let write = count("cacheWrite"), read = count("cacheRead"), hour = min(write, count("cacheWrite1h"))
                guard input > 0 || output > 0 || write > 0 || read > 0 else { continue }
                let key = SHA256.hash(data: fingerprint).map { String(format: "%02x", $0) }.joined()
                records[key] = TokenRecord(date: date, model: model, provider: provider, source: .pi,
                    input: input, output: output, cacheWrite: write, cacheRead: read,
                    cost: apiCost(model: model, input: input, output: output, cacheWrite5m: write - hour,
                                  cacheWrite1h: hour, cacheRead: read, fast: false), cacheWrite1h: hour)
            }
        }
        return Array(records.values)
    }
}
