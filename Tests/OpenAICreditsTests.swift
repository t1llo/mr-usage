// Synthetic usage responses and an isolated Codex log; no provider credentials or network access.
import Combine
import Foundation

@main
struct OpenAICreditsTests {
    static func main() async throws {
        let now = Date()
        func response(_ balance: Any, has: Bool = true, unlimited: Bool = false) -> [String: Any] {
            ["credits": ["has_credits": has, "unlimited": unlimited, "balance": balance]]
        }
        for value in ["1245.5", 1245.5] as [Any] {
            let live = parseCodexUsage(response(value), now: now)
            assert(live.hasData && live.usage.limits.isEmpty, "Credit-only accounts must remain displayable")
            assert(live.credits?.balance == 1245.5, "OpenAI credits must not be converted from cents")
            assert(live.credits?.asOf == now && live.credits?.live == true)
            assert(live.usage.credits == nil, "OpenAI balance must not become Claude monthly extra usage")
        }
        let empty = parseCodexUsage(response("0", has: false), now: now)
        assert(empty.hasData && empty.credits?.balance == 0)
        assert(empty.credits?.hasCredits == false)
        assert(parseCodexUsage(response("-3.25"), now: now).credits?.balance == -3.25,
               "An overdrawn balance must not be clamped to zero")
        assert(parseCodexUsage(response(NSNull()), now: now).credits?.displayBalance == "Available")
        assert(parseCodexUsage(response("0", unlimited: true), now: now).credits?.displayBalance == "Unlimited")
        for value in [true, "not-a-number", "NaN", "inf", Double.infinity] as [Any] {
            assert(parseCodexUsage(response(value), now: now).credits?.balance == nil,
                   "Malformed balances must not become numbers or non-finite display values")
        }
        assert(parseCodexUsage([:], now: now).credits == nil)
        assert(parseCodexUsage(["credits": NSNull()], now: now).credits == nil)
        assert(!parseCodexUsage(["credits": [:]], now: now).hasData)
        print("PASS: credit units, string/numeric balances, zero, negative, unlimited and unavailable values")

        let window: [String: Any] = ["used_percent": 12.0, "limit_window_seconds": 300 * 60,
                                     "reset_at": now.addingTimeInterval(600).timeIntervalSince1970]
        let dayWindow: [String: Any] = ["used_percent": 34.0, "limit_window_seconds": 86_400,
                                        "reset_after_seconds": 1200]
        let plan = parseCodexUsage([
            "plan_type": "prolite",
            "rate_limit": ["primary_window": window, "secondary_window": dayWindow,
                           "tertiary_window": ["used_percent": 56.0, "limit_window_seconds": 7 * 86_400]],
            "additional_rate_limits": [
                ["limit_name": "Fast model", "metered_feature": "fast_model", "rate_limit": ["primary_window": window]],
                ["limit_name": "Other model", "metered_feature": "other_model", "rate_limit": ["secondary_window": dayWindow]],
                ["limit_name": "No allowance", "rate_limit": NSNull()]
            ]
        ], now: now)
        assert(plan.usage.limits.map(\.label) == ["Session", "Day", "Week", "Fast model · Session", "Other model · Day"],
               "Unexpected labels: \(plan.usage.limits.map(\.label))")
        assert(plan.usage.limits[1].resetsAt == now.addingTimeInterval(1200))
        assert(plan.usage.limits[1].window == 86_400 && plan.plan == "prolite")
        assert(Set(plan.usage.limits.map(\.id)).count == 5)
        let additionalOnly = parseCodexUsage(["additional_rate_limits": [
            ["limit_name": "Model", "rate_limit": ["primary_window": window]]
        ]], now: now)
        assert(additionalOnly.hasData && additionalOnly.usage.limits.count == 1)
        let invalid = parseCodexUsage(["rate_limit": ["primary_window": ["used_percent": Double.nan],
            "secondary_window": ["used_percent": -1.0]]], now: now)
        assert(!invalid.hasData)
        print("PASS: server-defined daily/weekly windows, additional feature groups, reset delays and malformed values")

        var logged = response("80.25")
        let captured = now.addingTimeInterval(-60)
        logged["primary"] = ["used_percent": 95.0, "window_minutes": 300,
                             "resets_at": now.addingTimeInterval(-10).timeIntervalSince1970]
        let snapshot = parseCodexLogLimits(logged, asOf: captured)!
        assert(snapshot.credits?.balance == 80.25 && snapshot.credits?.live == false)
        assert(snapshot.current(now: now).limits.first?.pct == 0)
        assert(snapshot.credits?.balance == 80.25, "A plan-window reset must not reset the credit balance")
        let newer = parseCodexLogLimits(["primary": ["used_percent": 5.0]], asOf: now,
                                        lastCredits: snapshot.credits)!
        assert(newer.asOf == now && newer.credits?.asOf == captured,
               "Missing balance data must preserve the earlier balance's own timestamp")
        assert(parseCodexLogLimits(response("0", has: false), asOf: now,
                                   lastCredits: snapshot.credits)?.credits?.balance == 0,
               "An explicit zero replaces the previous positive balance")
        assert(parseCodexLogLimits([:], asOf: now) == nil)
        print("PASS: logged fallback, independent timestamps, exhausted balances and window resets")

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("openai-credits-\(UUID().uuidString)")
        let previousHome = ProcessInfo.processInfo.environment["CODEX_HOME"]
        defer {
            if let previousHome { setenv("CODEX_HOME", previousHome, 1) } else { unsetenv("CODEX_HOME") }
            try? FileManager.default.removeItem(at: folder)
        }
        setenv("CODEX_HOME", folder.path, 1)
        assert(CodexScanner.home.path == folder.path)
        let sessions = folder.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let log = sessions.appendingPathComponent("credits.jsonl")
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        func line(_ offset: Double, _ bucket: String, _ balance: Any? = nil) throws -> String {
            var rate: [String: Any] = ["limit_id": bucket, "primary": ["used_percent": 12.0]]
            if let balance { rate["credits"] = response(balance, has: (balance as? String) != "0")["credits"] }
            let json = String(decoding: try JSONSerialization.data(withJSONObject: rate), as: UTF8.self)
            return "{\"timestamp\":\"\(iso.string(from: now.addingTimeInterval(offset)))\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"rate_limits\":\(json)}}\n"
        }
        let first = try line(-60, "codex", "80.25") + line(-40, "codex") + line(-20, "codex_other", "9999")
        let final = try line(-10, "codex", "0")
        try Data((first + String(final.dropLast())).utf8).write(to: log)
        let scanner = CodexScanner()
        let initialScan = await scanner.scan()
        assert(initialScan.found && initialScan.records.isEmpty)
        assert(initialScan.limits?.credits?.balance == 80.25,
               "A newer snapshot without credits and another bucket must not erase the saved balance")
        assert(initialScan.limits?.usage.limits.count == 2,
               "Additional logged buckets must be shown without replacing the main plan or its credits")
        let handle = try FileHandle(forWritingTo: log)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("\n".utf8))
        try handle.close()
        let completedScan = await scanner.scan()
        assert(completedScan.limits?.credits?.balance == 0,
               "An appended complete line must update the balance exactly once")
        print("PASS: incremental Codex scanning, missing credits, other buckets and incomplete log lines")
    }
}
