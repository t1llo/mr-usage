import Foundation

@main
struct ClaudePollingTests {
    @MainActor static func main() throws {
        let name = "MrUsage.ClaudePollingTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let usage = Usage(limits: [Limit(id: "five_hour", label: "Session", pct: 34,
                                         resetsAt: now.addingTimeInterval(9000), window: 18000)],
                          credits: Credits(usedCents: 125, limitCents: 500))
        var state = ClaudePollingState()
        assert(state.begin(at: now))
        state.succeeded(usage, at: now)
        state.save(to: defaults)

        var restored = ClaudePollingState.load(from: defaults)
        assert(!restored.begin(at: now.addingTimeInterval(59)), "Restarting must preserve the request-start gate")
        assert(restored.begin(at: now.addingTimeInterval(60)))
        restored.failed(FetchError.http(429, retryAfter: 3600, message: "Rate limited. Please try again later."),
                        at: now.addingTimeInterval(61))
        restored.save(to: defaults)

        let store = Store(defaults: defaults, startPolling: false)
        assert(store.usage?.limits.first?.pct == 34 && store.usage?.credits?.usedCents == 125)
        assert(store.lastGoodAt == now && store.nextFetchAt == now.addingTimeInterval(3661))
        assert(store.lastError == "rate limited" && store.status.contains("Showing limits from"))
        var afterRestart = ClaudePollingState.load(from: defaults)
        assert(!afterRestart.begin(at: now.addingTimeInterval(3660)), "Manual refresh/relaunch must honor a long Retry-After")
        assert(afterRestart.begin(at: now.addingTimeInterval(3661)))
        afterRestart.succeeded(usage, at: now.addingTimeInterval(3662))
        assert(afterRestart.interval == 120, "Success must not reset learned throttling")
        print("PASS: persisted good usage, credit units, request gates, long cooldowns and success without resetting backoff")

        for _ in 0..<6 { afterRestart.failed(FetchError.http(503, retryAfter: nil, message: nil), at: now) }
        assert(afterRestart.interval == 600 && afterRestart.usage?.limits.first?.pct == 34)
        afterRestart.failed(FetchError.noToken, at: now)
        assert(afterRestart.interval == 600 && afterRestart.lastGoodAt != nil)
        defaults.set(Data("broken cache".utf8), forKey: ClaudePollingState.defaultsKey)
        assert(ClaudePollingState.load(from: defaults).interval == 60)
        print("PASS: bounded exponential backoff, last-good retention on failures and corrupt-cache recovery")

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        let date = formatter.string(from: now.addingTimeInterval(1800))
        assert(retryAfterDelay(" 900 ", now: now) == 900)
        assert(retryAfterDelay(date, now: now) == 1800)
        assert(retryAfterDelay(date, now: now.addingTimeInterval(3600)) == 0)
        for invalid in ["-1", "NaN", "infinity", "", "later"] { assert(retryAfterDelay(invalid, now: now) == nil) }
        assert(FetchError.http(429, retryAfter: nil, message: "Rate limited. Please try again later.").localizedDescription == "rate limited")
        print("PASS: numeric and HTTP-date Retry-After parsing and concise throttle messages")
    }
}
