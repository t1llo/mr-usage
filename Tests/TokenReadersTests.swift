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
        assert(summary.totalTokens == 100_150, "Total includes uncached input, output and both cache kinds")
        assert(summary.buckets.reduce(0) { $0 + $1.value } == 19)
        print("PASS: Claude streaming/copy deduplication, missing request IDs, cache TTL, ISO timestamps and partial lines")

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let chartNow = isoDate("2026-11-01T08:30:00Z")!
        let chartRecords = (0..<160).map { i in
            TokenRecord(date: chartNow.addingTimeInterval(Double(-i * 1800)),
                        model: i % 3 == 0 ? "unknown" : "gpt-5.1", provider: i % 4 == 0 ? .claude : .openai,
                        source: i % 2 == 0 ? .codex : .opencode,
                        input: i, output: i * 2, cacheWrite: i * 3, cacheRead: i * 4,
                        cost: i % 3 == 0 ? nil : Double(i) / 100)
        }
        for provider in Provider.allCases {
            for range in TokenRange.allCases {
                let batch = summarizeMetrics(chartRecords, provider: provider, range: range, now: chartNow, calendar: calendar)
                for metric in TokenMetric.allCases {
                    let summary = batch[metric]!
                    let selected = chartRecords.filter {
                        $0.provider == provider && $0.date >= summary.buckets.first!.start && $0.date <= chartNow
                    }
                    for kind in TokenMetric.allCases {
                        assert(abs((summary.totals[kind] ?? 0) - selected.reduce(0) { $0 + kind.value($1) }) < 0.00001)
                    }
                    for bucket in summary.buckets {
                        let expected = selected.filter {
                            calendar.dateInterval(of: range.unit, for: $0.date)!.start == bucket.start
                        }.reduce(0) { $0 + metric.value($1) }
                        assert(abs(bucket.value - expected) < 0.00001, "Buckets must remain correct across DST")
                    }
                    let tagged = Set(selected.map(\.source)).count > 1
                    let grouped = Dictionary(grouping: selected) {
                        modelName($0.model) + (tagged ? " · \($0.source.rawValue)" : "")
                    }.mapValues { $0.reduce(0) { $0 + metric.value($1) } }.filter { $0.value > 0 }
                    assert(Dictionary(uniqueKeysWithValues: summary.byModel.map { ($0.name, $0.value) }) == grouped)
                    assert(summary.unpriced == Set(selected.filter { $0.cost == nil }.map { modelName($0.model) }))
                }
            }
        }
        print("PASS: all chart metrics, provider/source grouping, unpriced models and DST bucket boundaries")

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

        let stats = parseClaudeActivity([
            "modelUsage": ["claude-sonnet-4-6": ["inputTokens": 9_116, "outputTokens": 4_376_078,
                "cacheReadInputTokens": 844_452_579, "cacheCreationInputTokens": 9_094_745]],
            "totalSessions": 20, "lastComputedDate": "2026-10-02", "firstSessionDate": "2026-09-01T10:00:00Z",
            "dailyActivity": [["date": "2026-10-01", "messageCount": 10],
                              ["date": "2026-10-02", "sessionCount": 1],
                              ["date": "2026-10-03", "messageCount": 0]]
        ], profile: "fixture")!
        assert(stats.totalTokens == 857_932_518 && stats.cacheRead == 844_452_579)
        assert(stats.sessions == 20 && stats.activeDays == 2 && stats.lastActive == "2026-10-02" && stats.firstSession != nil)
        assert(parseClaudeActivity([:], profile: "fixture") == nil)
        print("PASS: separate Claude lifetime stats, full token sum, cache scope and activity dates")

        let piFolder = folder.appendingPathComponent("pi-sessions")
        try FileManager.default.createDirectory(at: piFolder, withIntermediateDirectories: true)
        func piLine(_ provider: String, model: String, stamp: Double = 0) throws -> Data {
            var line = try JSONSerialization.data(withJSONObject: ["type": "message", "id": "entry-\(stamp)",
                "timestamp": iso.string(from: now), "message": ["role": "assistant", "provider": provider,
                "model": model, "timestamp": (now.timeIntervalSince1970 - stamp) * 1000,
                "content": [["type": "text", "text": "synthetic fixture"]],
                "usage": ["input": 3, "output": 20, "reasoning": 5, "cacheRead": 100_000,
                          "cacheWrite": 100, "cacheWrite1h": 40, "totalTokens": 100_123,
                          "cost": ["total": 0]]]])
            line.append(0x0A); return line
        }
        var piData = try piLine("anthropic", model: "claude-sonnet-4-6")
        piData.append(try piLine("openai-codex", model: "gpt-5.1", stamp: 1))
        piData.append(try piLine("openai", model: "unknown-model", stamp: 2))
        piData.append(try piLine("google", model: "gemini", stamp: 3))
        piData.append(Data("{\"type\":\"compaction\",\"tokensBefore\":999999}\n".utf8))
        piData.append(try piLine("anthropic", model: "claude-sonnet-4-6", stamp: 4).dropLast())
        let piLog = piFolder.appendingPathComponent("session.jsonl")
        try piData.write(to: piLog)
        try piData.write(to: piFolder.appendingPathComponent("fork.jsonl"))
        let pi = PiScanner(root: piFolder)
        let piRecords = await pi.scan()
        assert(piRecords.count == 3 && piRecords.allSatisfy { $0.source == .pi })
        assert(piRecords.allSatisfy { $0.input == 3 && $0.output == 20 && $0.cacheRead == 100_000 && $0.cacheWrite1h == 40 })
        assert(piRecords.first { $0.provider == .claude }?.cost == expected,
               "Pi reasoning is already included; costs are recalculated even if logged cost is zero")
        assert(piRecords.first { $0.model == "unknown-model" }?.cost == nil)
        let piCached = await pi.scan()
        assert(piCached.count == piRecords.count, "Unchanged files retain their deduplicated records")
        let piHandle = try FileHandle(forWritingTo: piLog)
        try piHandle.seekToEnd(); try piHandle.write(contentsOf: Data([0x0A])); try piHandle.close()
        let piComplete = await pi.scan()
        assert(piComplete.count == 4, "Only complete lines are read; fork copies count once")
        try FileManager.default.removeItem(at: piFolder.appendingPathComponent("fork.jsonl"))
        let piAfterDeletion = await pi.scan()
        assert(piAfterDeletion.count == 4, "Deleting a copied file must retain records in surviving files")
        let rewritten = try piLine("anthropic", model: "claude-sonnet-4-6", stamp: 8)
        try rewritten.write(to: piLog)
        let piRewritten = await pi.scan()
        assert(piRewritten.count == 1 && abs(piRewritten[0].date.timeIntervalSince(now.addingTimeInterval(-8))) < 0.001,
               "Rewritten files replace cached messages")
        try Data().write(to: piLog)
        let piRemoved = await pi.scan()
        assert(piRemoved.isEmpty, "Rewritten/deleted Pi records don't linger")
        print("PASS: Pi Claude/OpenAI mapping, fork deduplication, complete lines, cache TTL, reasoning and repricing")

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

        // Only synthetic files: no API-key commands, refresh tokens or credential writes.
        let previousPi = ProcessInfo.processInfo.environment["PI_CODING_AGENT_DIR"]
        defer {
            if let previousPi { setenv("PI_CODING_AGENT_DIR", previousPi, 1) } else { unsetenv("PI_CODING_AGENT_DIR") }
        }
        setenv("PI_CODING_AGENT_DIR", piFolder.path, 1)
        let piAuthFile = piFolder.appendingPathComponent("auth.json")
        let oauthData = try JSONSerialization.data(withJSONObject: ["anthropic": ["type": "oauth",
            "access": "fixture-pi", "expires": future, "refresh": "do-not-consume"]])
        try oauthData.write(to: piAuthFile)
        try JSONSerialization.data(withJSONObject: ["anthropic": ["type": "oauth", "access": "fixture-open", "expires": future]])
            .write(to: openCodeDataDirectory.appendingPathComponent("auth.json"))
        let piAuth = readClaudeAuth(source: .pi, directory: folder)
        let openAuth = readClaudeAuth(source: .opencode, directory: folder)
        assert(piAuth?.token == "fixture-pi" && piAuth?.source == .pi && !piAuth!.hasAccountMetadata)
        assert(openAuth?.token == "fixture-open" && openAuth?.source == .opencode)
        let unchangedAuth = try Data(contentsOf: piAuthFile)
        assert(unchangedAuth == oauthData, "OAuth reads must not modify credentials")
        try JSONSerialization.data(withJSONObject: ["anthropic": ["type": "api_key", "key": "!never-execute-this"]])
            .write(to: piAuthFile)
        assert(readClaudeAuth(source: .pi, directory: folder) == nil,
               "API-key login cannot supply subscription limits; do not fall through to OpenCode")
        print("PASS: read-only Pi/OpenCode OAuth selection, API-key exclusion and no cross-account fallback")
    }
}
