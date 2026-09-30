// Standalone assertions for aggregation and the app-to-website protocol.
// No TokenStore is created, and no real provider files or credentials are read.
import Combine
import Foundation

@main
struct LeaderboardTests {
    @MainActor static func main() async throws {
        let now = Date()
        let record = TokenRecord(date: now, model: "claude-sonnet-4-6", provider: .claude,
                                 source: .claudeCode, input: 1_000_000, output: 100_000,
                                 cacheWrite: 30_000, cacheRead: 500_000, cost: nil, cacheWrite1h: 10_000)
        let otherTool = TokenRecord(date: now, model: "gpt-5.1", provider: .openai, source: .opencode,
                                    input: 900, output: 900, cacheWrite: 0, cacheRead: 0, cost: nil)
        let accountEstimate = TokenRecord(date: now, model: "gpt-5.1", provider: .openai, source: .chatgpt,
                                          input: 999_999, output: 999_999, cacheWrite: 0, cacheRead: 0, cost: nil)
        let archived = SharedUsageBucket(day: "2023-01-01", provider: "claude", model: "claude-sonnet-4-6", inputTokens: 42)
        let first = archiveLeaderboardUsage([record, otherTool, accountEstimate], previous: [archived], now: now)
        let again = archiveLeaderboardUsage([record, otherTool, accountEstimate], previous: first, now: now)
        assert(again.count == 3)
        assert(again[0].inputTokens == 42)
        assert(again[1].inputTokens == 1_000_000, "Repeated scans must replace, not add to, recent totals")
        assert(again[1].cacheWriteTokens == 20_000)
        assert(again[1].cacheWrite1hTokens == 10_000)
        assert(again[2].provider == "codex" && again[2].inputTokens == 900, "OpenCode counts belong to their provider")
        assert(again.allSatisfy { $0.estimated != true }, "Unreconciled account records must not be added to local counts")
        var state = LeaderboardState()
        state.displayName = "fixture"
        state.archive = again
        assert(leaderboardSnapshot(state).buckets.isEmpty, "Unclassified history stays local")
        state.claudeBilling = .subscription
        let encoded = try JSONEncoder().encode(leaderboardSnapshot(state))
        let json = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        assert(Set(json.keys) == ["schemaVersion", "consent", "displayName", "buckets"])
        assert(leaderboardSnapshot(state).buckets.allSatisfy { $0.billing == "subscription" })
        let validName = try leaderboardDisplayName("  café.codes  ")
        assert(validName == "café.codes")
        for text in ["http://example.com", "https://example.com/path", "https://user:pass@example.com", "https://example.com?secret=1"] {
            do { _ = try leaderboardOrigin(text); assertionFailure("Should reject \(text)") } catch {}
        }
        _ = try leaderboardOrigin("https://example.com")
        _ = try leaderboardOrigin("http://127.0.0.1:4173")
        print("PASS: UTC aggregation, history retention, cache TTL, consent and URL validation")

        let calendar = usageUTCCalendar
        let today = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
        let account = TokenRecord(date: yesterday, model: "gpt-5.1", provider: .openai, source: .chatgpt,
                                  input: 2_000_000, output: 200_000, cacheWrite: 0, cacheRead: 1_000_000, cost: 4.625)
        let duplicate = TokenRecord(date: yesterday.addingTimeInterval(1), model: "gpt-6-astra", provider: .openai,
                                    source: .codex, input: 9_000_000, output: 0, cacheWrite: 0, cacheRead: 0, cost: nil)
        let openCodeDuplicate = TokenRecord(date: yesterday.addingTimeInterval(2), model: "gpt-5.1", provider: .openai,
                                            source: .opencode, input: 8_000_000, output: 0, cacheWrite: 0, cacheRead: 0, cost: nil)
        let local = [record, otherTool, duplicate, openCodeDuplicate]
        let combined = archiveLeaderboardUsage(local, account: [account], previous: [], now: now)
        let openai = combined.filter { $0.provider == "codex" }
        assert(openai.count == 2 && openai.reduce(0) { $0 + $1.inputTokens } == 2_000_900,
               "Account days replace ALL overlapping Codex/OpenCode models; unreported days keep local counts")
        assert(openai.filter { $0.estimated == true }.count == 1)
        assert(combined.contains { $0.provider == "claude" }, "OpenAI history must not replace Claude logs")
        let reconciled = reconciledOpenAIRecords(local: local, account: [account])
        assert(reconciled.count == 2 && reconciled.reduce(0) { $0 + $1.input } == 2_000_900,
               "The app's All devices chart and leaderboard must use the same day-level replacement")
        let offlineArchive = archiveLeaderboardUsage(local, previous: combined, now: now)
        assert(offlineArchive.filter { $0.estimated == true }.first?.inputTokens == 2_000_000,
               "A missing account response must retain known all-device days across restarts")
        let corrected = TokenRecord(date: yesterday, model: "gpt-6-astra", provider: .openai, source: .chatgpt,
                                    input: 4, output: 1, cacheWrite: 0, cacheRead: 5, cost: nil)
        let correction = archiveLeaderboardUsage(local, account: [corrected], previous: combined, now: now)
        assert(correction.filter { $0.estimated == true }.count == 1)
        assert(correction.filter { $0.estimated == true }.first?.inputTokens == 4,
               "Revised totals and model shares replace previous days, including downward corrections")
        let zero = TokenRecord(date: yesterday, model: "unknown", provider: .openai, source: .chatgpt,
                               input: 0, output: 0, cacheWrite: 0, cacheRead: 0, cost: nil)
        let zeroArchive = archiveLeaderboardUsage(local, account: [zero], previous: correction, now: now)
        let zeroOffline = archiveLeaderboardUsage(local, previous: zeroArchive, now: now)
        assert(zeroOffline.filter { $0.provider == "codex" }.reduce(0) { $0 + $1.inputTokens } == 900,
               "An explicitly empty account day must not revive overlapping local usage")
        let api = archiveLeaderboardUsage(local, account: [account], previous: combined, includeAccount: false, now: now)
        assert(api.allSatisfy { $0.estimated != true }, "Subscription account history must never be labelled API billed")
        assert(api.filter { $0.provider == "codex" }.reduce(0) { $0 + $1.inputTokens } == 17_000_900)
        var changedBilling = state
        changedBilling.archive = combined
        changedBilling.codexBilling = .api
        assert(leaderboardSnapshot(changedBilling).buckets.allSatisfy { $0.estimated != true },
               "A billing edit must not relabel archived subscription estimates as API spend")
        let migrated = try JSONDecoder().decode(SharedUsageBucket.self, from: Data("""
        {"day":"2023-01-01","provider":"codex","model":"gpt-5.1","billing":"subscription","inputTokens":12,"outputTokens":0,"cacheReadTokens":0,"cacheWriteTokens":0,"cacheWrite1hTokens":0}
        """.utf8))
        assert(migrated.estimated == nil && migrated.inputTokens == 12)
        print("PASS: all-device/local reconciliation, repeat scans, corrections, outage retention and billing isolation")

        let oldZone = NSTimeZone.default
        NSTimeZone.default = TimeZone(secondsFromGMT: 12 * 3600)!
        let activity = parseAccountActivity([
            "stats": ["lifetime_tokens": 101.0, "daily_usage_buckets": [["start_date": "2026-01-01", "tokens": 101.0],
                                                                     ["start_date": "2026-01-02", "tokens": 0.0]]],
            "metadata": ["stats_as_of": "2026-01-02"]
        ], breakdown: ["data": [["date": "2026-01-01", "models": [["model": "gpt-5.1", "credits": 1.0],
                                                                   ["model": "gpt-6-astra", "credits": 2.0]]]]])!
        NSTimeZone.default = oldZone
        let utcDay = ISO8601DateFormatter().date(from: "2026-01-01T00:00:00Z")!
        assert(activity.daily[utcDay] == 101, "An account day must not shift into the previous UTC day")
        let estimates = estimatedRecords(activity, mix: .codex)
        assert(estimates.reduce(0) { $0 + $1.input + $1.output + $1.cacheRead + $1.cacheWrite } == 101,
               "Estimated model/kind splits must preserve the exact reported token total")
        assert(Set(estimates.map(\.date)).count == 2, "Keep zero-token days for deduplication")
        print("PASS: UTC account dates, zero-day coverage and lossless estimated token allocation")

        // A settings draft must survive a restart without opting into uploads,
        // allocating an identity, or needing the production domain to exist yet.
        let draftFolder = FileManager.default.temporaryDirectory.appendingPathComponent("leaderboard-draft-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: draftFolder) }
        let draftURL = draftFolder.appendingPathComponent("state.json")
        let draftRecords = PassthroughSubject<TokenSnapshot, Never>()
        let draft = LeaderboardStore(usage: draftRecords.eraseToAnyPublisher(), stateURL: draftURL)
        draft.saveProfile(name: "  café.codes  ", claude: .unclassified, codex: .unclassified)
        draftRecords.send(TokenSnapshot(local: [record]))
        assert(draft.lastError == nil)
        assert(!draft.state.enabled && !draft.inFlight && draft.state.token.isEmpty)
        assert(draft.state.website.isEmpty && draft.state.archive.isEmpty)
        let restored = LeaderboardStore(usage: draftRecords.eraseToAnyPublisher(), stateURL: draftURL)
        assert(restored.state.displayName == "café.codes")
        assert(restored.state.claudeBilling == .unclassified && !restored.state.enabled)
        restored.saveProfile(name: "builder", claude: .subscription, codex: .api)
        let saved = try Data(contentsOf: draftURL)
        let profile = try JSONDecoder().decode(LeaderboardState.self, from: saved)
        assert(profile.displayName == "builder" && profile.claudeBilling == .subscription && profile.codexBilling == .api)
        assert(!profile.enabled && profile.token.isEmpty)
        restored.saveProfile(name: "!", claude: .api, codex: .unclassified)
        let afterInvalidEdit = try Data(contentsOf: draftURL)
        assert(restored.lastError != nil && afterInvalidEdit == saved, "Invalid edits must preserve the saved profile")
        print("PASS: local profile persistence without sharing and invalid-edit preservation")

        // Optional real end-to-end sync against the website's local preview.
        guard let origin = ProcessInfo.processInfo.environment["LEADERBOARD_TEST_ORIGIN"] else { return }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("leaderboard-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let stateURL = folder.appendingPathComponent("state.json")
        let records = PassthroughSubject<TokenSnapshot, Never>()
        let store = LeaderboardStore(usage: records.eraseToAnyPublisher(), stateURL: stateURL)
        records.send(TokenSnapshot(local: local, account: [account]))
        assert(!store.state.enabled && !FileManager.default.fileExists(atPath: stateURL.path))
        let name = "test-" + UUID().uuidString.prefix(12)
        store.enable(name: name, website: origin, claude: .subscription, codex: .subscription)
        try await wait { store.state.lastSynced != nil && !store.inFlight }
        assert(store.lastError == nil, store.lastError ?? "")
        assert(store.state.token.count == 64)
        let url = URL(string: origin + "/api/v1/leaderboard?search=" + name)!
        let (response, _) = try await URLSession.shared.data(from: url)
        let board = try JSONSerialization.jsonObject(with: response) as! [String: Any]
        let entry = (board["entries"] as! [[String: Any]])[0]
        assert(entry["tokens"] as! Int == 4_831_800)
        assert(entry["estimatedTokens"] as! Int == 3_200_000)
        assert(abs((entry["costUsd"] as! Double) - 9.420125) < 0.000001)
        // Removal requested while another write is queued/in flight must win.
        store.enable(name: name, website: origin, claude: .subscription, codex: .subscription)
        store.disable()
        try await wait { !store.state.pendingRemoval && !store.inFlight }
        let (removed, _) = try await URLSession.shared.data(from: url)
        let empty = try JSONSerialization.jsonObject(with: removed) as! [String: Any]
        assert((empty["entries"] as! [Any]).isEmpty)
        let persisted = try JSONDecoder().decode(LeaderboardState.self, from: Data(contentsOf: stateURL))
        assert(!persisted.enabled && !persisted.pendingRemoval && persisted.archive.isEmpty)
        let attributes = try FileManager.default.attributesOfItem(atPath: stateURL.path)
        assert((attributes[.posixPermissions] as! NSNumber).intValue == 0o600)
        print("PASS: native Swift upload, server pricing, dedicated identity and serialized opt-out")

        let offlineURL = folder.appendingPathComponent("offline/state.json")
        let offline = LeaderboardStore(usage: records.eraseToAnyPublisher(), stateURL: offlineURL)
        // With no records emitted to this new subscriber, opt-in is saved but no
        // upload starts. Removal must persist even with an unreachable server.
        offline.enable(name: "offline-fixture", website: "http://127.0.0.1:0", claude: .subscription, codex: .unclassified)
        offline.disable()
        try await wait { !offline.inFlight }
        let pending = try JSONDecoder().decode(LeaderboardState.self, from: Data(contentsOf: offlineURL))
        assert(!pending.enabled && pending.pendingRemoval && !pending.token.isEmpty)
        assert(offline.nextAttemptAt > Date(), "Failures must back off rather than retrying continuously")
        let restarted = LeaderboardStore(usage: records.eraseToAnyPublisher(), stateURL: offlineURL)
        assert(!restarted.state.enabled && restarted.state.pendingRemoval)
        try await wait { !restarted.inFlight }
        print("PASS: offline opt-out survives restart and keeps the deletion credential")
    }

    @MainActor private static func wait(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(15)
        while !condition() {
            guard Date() < deadline else { throw LeaderboardError.message("Test timed out") }
            try await Task.sleep(nanoseconds: 30_000_000)
        }
    }
}
