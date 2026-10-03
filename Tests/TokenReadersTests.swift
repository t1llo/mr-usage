// Isolated synthetic logs/databases; no real conversations, credentials or provider requests.
import Combine
import Foundation
import SQLite3

@main
struct TokenReadersTests {
    static func main() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("token-readers-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let now = Date()
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let log = folder.appendingPathComponent("claude.jsonl")
        func assistant(_ id: String, uuid: String, request: String? = nil,
                       usage: [String: Any], timestamp: String? = nil) throws -> Data {
            var json: [String: Any] = ["type": "assistant", "uuid": uuid,
                "timestamp": timestamp ?? iso.string(from: now),
                "message": ["id": id, "model": "claude-sonnet-4-6", "usage": usage]]
            if let request { json["requestId"] = request }
            var data = try JSONSerialization.data(withJSONObject: json)
            data.append(0x0A)
            return data
        }
        let usage: [String: Any] = ["input_tokens": 3, "output_tokens": 10,
            "cache_creation_input_tokens": 100, "cache_read_input_tokens": 100_000,
            "cache_creation": ["ephemeral_1h_input_tokens": 40]]
        var lines = try assistant("response-1", uuid: "block-1", usage: usage)
        lines.append(try assistant("response-1", uuid: "block-2", usage: ["output_tokens": 20]))
        // A resumed copy can omit/change request metadata, but not the response identity.
        lines.append(try assistant("response-1", uuid: "copy", request: "request-1", usage: usage))
        lines.append(try assistant("response-2", uuid: "other", usage: ["input_tokens": 7, "output_tokens": 5],
                                   timestamp: ISO8601DateFormatter().string(from: now)))
        let tail = try assistant("response-3", uuid: "tail", usage: ["input_tokens": 9, "output_tokens": 6])
        lines.append(tail.dropLast())
        try lines.write(to: log)
        let scanner = TokenScanner(root: folder)
        let initial = await scanner.scan()
        assert(initial.count == 2, "Streaming blocks, request metadata changes and resumed copies count once")
        let response = initial.first { $0.cacheRead > 0 }!
        assert(response.input == 3 && response.output == 20 && response.cacheRead == 100_000)
        assert(response.cacheWrite == 100 && response.cacheWrite1h == 40,
               "Partial streaming updates must not erase input or TTL fields")
        let expected = apiCost(model: response.model, input: 3, output: 20, cacheWrite5m: 60,
                               cacheWrite1h: 40, cacheRead: 100_000, fast: false)
        assert(response.cost == expected)
        let handle = try FileHandle(forWritingTo: log)
        try handle.seekToEnd(); try handle.write(contentsOf: Data([0x0A])); try handle.close()
        let complete = await scanner.scan()
        let repeated = await scanner.scan()
        assert(complete.count == 3 && repeated.count == 3)
        let summary = summarize(complete, provider: .claude, range: .week, metric: .input, now: now.addingTimeInterval(1))
        assert(summary.totals[.input] == 19 && summary.totals[.output] == 31)
        assert(summary.totals[.cacheRead] == 100_000 && summary.totals[.cacheWrite] == 100)
        assert(summary.buckets.reduce(0) { $0 + $1.value } == 19)
        print("PASS: Claude streaming/copy deduplication, missing request IDs, cache TTL, ISO timestamps and partial lines")

        let future = now.addingTimeInterval(600).timeIntervalSince1970 * 1000
        let expired = now.addingTimeInterval(-600).timeIntervalSince1970 * 1000
        assert(claudeOAuthToken(["accessToken": "fixture", "expiresAt": future], now: now) == "fixture")
        assert(claudeOAuthToken(["accessToken": "fixture", "expiresAt": expired], now: now) == nil)
        assert(claudeOAuthToken(["access": "opencode", "expires": future], openCode: true, now: now) == "opencode")
        assert(claudeOAuthToken(["access": "opencode", "expires": expired], openCode: true, now: now) == nil)
        assert(claudeOAuthToken(["refresh": "never-use-this"], openCode: true, now: now) == nil)
        let limits = parse(["five_hour": ["utilization": 12.0], "seven_day": ["utilization": 34.0],
                            "seven_day_new_model": ["utilization": 56.0], "seven_day_invalid": ["utilization": Double.nan]])
        assert(limits.limits.map(\.label) == ["Session", "Week", "Week · New Model"])
        print("PASS: read-only Claude OAuth expiry and additional Claude model windows")

        let previousHome = ProcessInfo.processInfo.environment["CODEX_HOME"]
        let previousData = ProcessInfo.processInfo.environment["XDG_DATA_HOME"]
        defer {
            if let previousHome { setenv("CODEX_HOME", previousHome, 1) } else { unsetenv("CODEX_HOME") }
            if let previousData { setenv("XDG_DATA_HOME", previousData, 1) } else { unsetenv("XDG_DATA_HOME") }
        }
        setenv("CODEX_HOME", folder.path, 1)
        let sessions = folder.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let codexLog = sessions.appendingPathComponent("rollout.jsonl")
        func codexLine(_ type: String, _ payload: [String: Any]) throws -> Data {
            var line = try JSONSerialization.data(withJSONObject: ["timestamp": iso.string(from: now), "type": type, "payload": payload],
                                                   options: [.sortedKeys])
            line.append(0x0A)
            return line
        }
        let counts: [String: Any] = ["input_tokens": 100, "cached_input_tokens": 80,
                                   "output_tokens": 10, "reasoning_output_tokens": 6, "total_tokens": 110]
        var codexLines = try codexLine("session_meta", ["id": "thread"])
        codexLines.append(try codexLine("turn_context", ["model": "gpt-5.1"]))
        codexLines.append(try codexLine("event_msg", ["type": "token_count",
            "info": ["last_token_usage": counts, "total_token_usage": counts]]))
        codexLines.append(try codexLine("token_usage_record", ["thread_id": "thread", "response_id": "response", "usage": counts]))
        try codexLines.write(to: codexLog)
        let codex = CodexScanner()
        let cx = await codex.scan()
        assert(cx.records.count == 1, "Per-response records supersede running totals, rather than adding to them")
        assert(cx.records[0].input == 20 && cx.records[0].cacheRead == 80 && cx.records[0].output == 10,
               "Codex input includes cache reads, and output already includes reasoning")
        print("PASS: Codex per-response precedence and provider-specific cache/reasoning normalization")

        setenv("XDG_DATA_HOME", folder.path, 1)
        try FileManager.default.createDirectory(at: OpenCodeReader.dataDir, withIntermediateDirectories: true)
        var db: OpaquePointer?
        assert(sqlite3_open(OpenCodeReader.dataDir.appendingPathComponent("opencode-fixture.db").path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        assert(sqlite3_exec(db, "CREATE TABLE message (time_created INTEGER, data TEXT);", nil, nil, nil) == SQLITE_OK)
        func insert(_ provider: String, model: String, offset: Double = 0) throws {
            let created = Int64((now.timeIntervalSince1970 + offset) * 1000)
            let json = try JSONSerialization.data(withJSONObject: ["role": "assistant", "providerID": provider, "modelID": model,
                "time": ["created": created, "completed": created + 1],
                "tokens": ["input": 3, "output": 10, "reasoning": 5, "cache": ["read": 100, "write": 20]]])
            let sql = "INSERT INTO message VALUES (\(created), '\(String(decoding: json, as: UTF8.self))');"
            assert(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
        }
        try insert("anthropic", model: "claude-sonnet-4-6")
        try insert("anthropic", model: "claude-sonnet-4-6") // fork copy
        try insert("openai", model: "openai/gpt-5.1-high", offset: -1)
        let openCode = OpenCodeReader()
        let oc = await openCode.scan()
        assert(oc.found && oc.records.count == 2)
        assert(oc.records.allSatisfy { $0.input == 3 && $0.output == 15 && $0.cacheRead == 100 && $0.cacheWrite == 20 })
        assert(oc.records.contains { $0.provider == .openai && $0.model == "gpt-5.1" && $0.cost != nil })
        assert(sqlite3_exec(db, "DELETE FROM message;", nil, nil, nil) == SQLITE_OK)
        let removed = await openCode.scan()
        assert(removed.records.isEmpty, "Mutable OpenCode rows are reread, not accumulated")
        print("PASS: OpenCode provider mapping, fork deduplication, model normalization and mutable rows")
    }
}
