import Foundation

@main
struct ClaudePollingTests {
    @MainActor static func main() async throws {
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
        assert(store.lastError == "rate limited" && store.status.contains("HTTP 429"))
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

        // Identity changes must remove old percentages without resetting the global gate.
        let personal = ClaudeAuth(token: "fixture-personal", source: .claudeCode, identity: "personal", label: "Personal fixture")
        let team = ClaudeAuth(token: "fixture-team", source: .claudeCode, identity: "team", label: "Team fixture")
        var identityState = ClaudePollingState()
        assert(identityState.begin(at: now))
        identityState.selectIdentity(personal)
        identityState.succeeded(usage, at: now)
        identityState.failed(FetchError.http(429, retryAfter: 7200, message: nil), at: now)
        let gate = identityState.nextFetchAt, interval = identityState.interval
        identityState.selectIdentity(team)
        assert(identityState.usage == nil && identityState.lastGoodAt == nil && identityState.authLabel == "Team fixture")
        assert(identityState.nextFetchAt == gate && identityState.interval == interval)
        identityState.save(to: defaults)
        let persisted = String(data: defaults.data(forKey: ClaudePollingState.defaultsKey)!, encoding: .utf8)!
        assert(!persisted.contains("fixture-team") && !persisted.contains("fixture-personal"), "Never persist OAuth tokens")
        let custom = URL(fileURLWithPath: "/synthetic/team-profile")
        assert(claudeKeychainServices(directory: custom).count == 1)
        assert(claudeKeychainServices(directory: custom)[0].hasPrefix("Claude Code-credentials-"))
        assert(!claudeKeychainServices(directory: custom).contains("Claude Code-credentials"), "Custom profiles must not read the personal item")
        print("PASS: isolated personal/Team identity, profile-specific Keychain services and credential-free persistence")

        defaults.removePersistentDomain(forName: name)
        let fixture = AuthFixture(now: now, auth: personal, usage: usage)
        let tracked = Store(defaults: defaults, startPolling: false,
                            readAuth: { source, _ in fixture.read(source) }, fetchLimits: { try fixture.fetch($0) },
                            currentDate: { fixture.date })
        tracked.tick(); tracked.tick()
        try await wait(tracked)
        assert(fixture.requests == 1 && fixture.sources == [.automatic])
        assert(tracked.displayUsage()?.limits.first?.pct == 34)
        fixture.advance(60); fixture.auth = nil
        tracked.tick()
        try await wait(tracked)
        assert(fixture.requests == 2 && fixture.sources.last == .claudeCode,
               "Automatic stays pinned; temporary credential-read failure keeps the cached token")
        fixture.advance(60); fixture.auth = team; fixture.error = FetchError.http(429, retryAfter: 7200, message: nil)
        tracked.tick()
        try await wait(tracked)
        assert(tracked.usage == nil && tracked.authLabel == "Team fixture", "Do not show personal limits for a new Team login")
        let longGate = tracked.nextFetchAt
        tracked.setLoginSource(.opencode)
        tracked.tick()
        assert(tracked.usage == nil && tracked.nextFetchAt == longGate && fixture.requests == 3,
               "Selecting another tool cannot bypass throttling or launch parallel calls")
        fixture.advance(7200); fixture.auth = ClaudeAuth(token: "fixture-open", source: .opencode, identity: "open", label: "OpenCode fixture")
        fixture.error = nil
        tracked.tick()
        try await wait(tracked)
        assert(fixture.sources.last == .opencode && tracked.usage != nil)
        assert(tracked.displayUsage(now: now.addingTimeInterval(9001))?.limits.isEmpty == true,
               "Expired windows are unknown, not an invented zero; independent credits remain")
        let latest = Usage(limits: [Limit(id: "five_hour", label: "Session", pct: 8,
                                        resetsAt: fixture.date.addingTimeInterval(18000), window: 18000)])
        fixture.usage = latest; fixture.advance(120)
        tracked.tick()
        try await wait(tracked)
        assert(tracked.displayUsage()?.limits.first?.pct == 8)
        assert(tracked.displayUsage(now: fixture.date.addingTimeInterval(3601)) == nil, "Hide hours-old percentages even before reset")
        assert(tracked.usage?.limits.first?.pct == 8, "Keep last-good data internally")
        print("PASS: automatic source pinning, temporary Keychain failures, in-flight guards, profile switching and stale/expired readings")
    }

    @MainActor private static func wait(_ store: Store) async throws {
        for _ in 0..<500 {
            if !store.inFlight { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw NSError(domain: "fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "Synthetic fetch timed out"])
    }
}

/// Read runs on a detached thread; fetch and clock updates use the test's main actor.
private final class AuthFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var storedAuth: ClaudeAuth?
    private var storedSources: [ClaudeLoginSource] = []
    var date: Date
    var usage: Usage
    var error: Error?
    var requests = 0
    init(now: Date, auth: ClaudeAuth, usage: Usage) { date = now; storedAuth = auth; self.usage = usage }
    var auth: ClaudeAuth? {
        get { lock.lock(); defer { lock.unlock() }; return storedAuth }
        set { lock.lock(); defer { lock.unlock() }; storedAuth = newValue }
    }
    var sources: [ClaudeLoginSource] { lock.lock(); defer { lock.unlock() }; return storedSources }
    func read(_ source: ClaudeLoginSource) -> ClaudeAuth? {
        lock.lock(); defer { lock.unlock() }
        storedSources.append(source)
        return storedAuth
    }
    func advance(_ seconds: TimeInterval) { date = date.addingTimeInterval(seconds) }
    func fetch(_ token: String) throws -> Usage {
        requests += 1
        assert(token.hasPrefix("fixture-"))
        if let error { throw error }
        return usage
    }
}
