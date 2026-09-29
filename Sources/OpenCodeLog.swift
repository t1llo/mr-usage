// Token counts from OpenCode, which keeps every session in one SQLite database
// (~/.local/share/opencode/opencode.db, WAL mode). Each assistant message row carries the
// provider, model and token counts of one model call. OpenCode logs the ChatGPT subscription
// login as provider "openai" with cost 0, so the API cost is recomputed here from list prices.
import Foundation
import SQLite3

actor OpenCodeReader {
    static var dataDir: URL {
        let base = ProcessInfo.processInfo.environment["XDG_DATA_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share")
        return base.appendingPathComponent("opencode")
    }

    /// Release builds write opencode.db, dev builds opencode-<channel>.db.
    private var databases: [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: Self.dataDir.path)) ?? []
        return names.filter { $0.hasPrefix("opencode") && $0.hasSuffix(".db") }.map { Self.dataDir.appendingPathComponent($0) }
    }

    /// Re-reads the horizon on every pass: rows are updated in place while a reply streams and
    /// deleted on revert, so an incremental cursor would drift.
    func scan() -> (records: [TokenRecord], found: Bool) {
        let dbs = databases
        let since = Int64((Date().timeIntervalSince1970 - TokenScanner.horizon) * 1000)
        // Forking a session copies its messages under new ids with identical contents, so dedupe
        // on the contents rather than the id.
        var seen = Set<String>()
        var out: [TokenRecord] = []
        for url in dbs {
            for r in query(url, since: since) where seen.insert(r.key).inserted { out.append(r.record) }
        }
        return (out, !dbs.isEmpty)
    }

    /// Opened through SQLite itself, so writes still sitting in the -wal file are seen. A
    /// read-only connection cannot recreate the -wal and -shm files OpenCode removes when it
    /// quits, so if it cannot read, retry as a normal connection. Either way it only runs SELECTs.
    private func query(_ url: URL, since: Int64) -> [(key: String, record: TokenRecord)] {
        query(url, since: since, flags: SQLITE_OPEN_READONLY)
            ?? query(url, since: since, flags: SQLITE_OPEN_READWRITE) ?? []
    }

    private func query(_ url: URL, since: Int64, flags: Int32) -> [(key: String, record: TokenRecord)]? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, flags, nil) == SQLITE_OK else { sqlite3_close(db); return nil }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 2000)
        let sql = """
            SELECT json_extract(data,'$.providerID'), json_extract(data,'$.modelID'),
                   json_extract(data,'$.time.created'), json_extract(data,'$.time.completed'),
                   json_extract(data,'$.tokens.input'), json_extract(data,'$.tokens.output'),
                   json_extract(data,'$.tokens.reasoning'), json_extract(data,'$.tokens.cache.read'),
                   json_extract(data,'$.tokens.cache.write')
            FROM message
            WHERE time_created >= ? AND json_extract(data,'$.role') = 'assistant'
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, since)
        var rows: [(String, TokenRecord)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let text = { (i: Int32) in sqlite3_column_text(stmt, i).map { String(cString: $0) } ?? "" }
            let int = { (i: Int32) in Int(sqlite3_column_int64(stmt, i)) }
            let providerID = text(0)
            let provider: Provider
            switch providerID {
            case "openai", "azure": provider = .openai
            case "anthropic": provider = .claude
            default: continue  // Copilot, OpenRouter, Zen and others bill differently
            }
            let model = normalize(text(1))
            let input = int(4), output = int(5) + int(6), read = int(7), write = int(8)
            guard input + output + read + write > 0 else { continue }  // not yet answered
            let date = Date(timeIntervalSince1970: Double(int(2)) / 1000)
            // OpenCode's input excludes both cache reads and writes, like Anthropic's. Its output
            // excludes reasoning, which bills as output, so the two are added back together.
            let cost = provider == .openai
                ? openAICost(model: model, input: input, output: output, cacheWrite: write, cacheRead: read)
                : apiCost(model: model, input: input, output: output, cacheWrite5m: write, cacheWrite1h: 0,
                          cacheRead: read, fast: false)
            let key = [providerID, model, text(2), text(3), "\(input)", "\(output)", "\(read)", "\(write)"].joined(separator: "|")
            rows.append((key, TokenRecord(date: date, model: model, provider: provider, source: .opencode,
                                          input: input, output: output, cacheWrite: write, cacheRead: read, cost: cost)))
        }
        return rows
    }

    /// "openai/gpt-5.2-medium" -> "gpt-5.2". Some auth plugins put the reasoning effort in the id.
    private func normalize(_ id: String) -> String {
        var m = id.split(separator: "/").last.map(String.init) ?? id
        for effort in ["-minimal", "-low", "-medium", "-high", "-xhigh"] where m.hasSuffix(effort) {
            m.removeLast(effort.count)
        }
        return m
    }
}
