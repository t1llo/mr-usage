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
        assert(again.count == 2)
        assert(again[0].inputTokens == 42)
        assert(again[1].inputTokens == 1_000_000, "Repeated scans must replace, not add to, recent totals")
        assert(again[1].cacheWriteTokens == 20_000)
        assert(again[1].cacheWrite1hTokens == 10_000)
        assert(again.allSatisfy { $0.provider == "claude" }, "OpenCode is not shared by this integration")
        assert(again.count == 2, "All-devices account estimates must not double-count local records")
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

        // A settings draft must survive a restart without opting into uploads,
        // allocating an identity, or needing the production domain to exist yet.
        let draftFolder = FileManager.default.temporaryDirectory.appendingPathComponent("leaderboard-draft-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: draftFolder) }
        let draftURL = draftFolder.appendingPathComponent("state.json")
        let draftRecords = PassthroughSubject<[TokenRecord], Never>()
        let draft = LeaderboardStore(records: draftRecords.eraseToAnyPublisher(), stateURL: draftURL)
        draft.saveProfile(name: "  café.codes  ", claude: .unclassified, codex: .unclassified)
        draftRecords.send([record])
        assert(draft.lastError == nil)
        assert(!draft.state.enabled && !draft.inFlight && draft.state.token.isEmpty)
        assert(draft.state.website.isEmpty && draft.state.archive.isEmpty)
        let restored = LeaderboardStore(records: draftRecords.eraseToAnyPublisher(), stateURL: draftURL)
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
        let records = PassthroughSubject<[TokenRecord], Never>()
        let store = LeaderboardStore(records: records.eraseToAnyPublisher(), stateURL: stateURL)
        records.send([record])
        assert(!store.state.enabled && !FileManager.default.fileExists(atPath: stateURL.path))
        let name = "test-" + UUID().uuidString.prefix(12)
        store.enable(name: name, website: origin, claude: .subscription, codex: .unclassified)
        try await wait { store.state.lastSynced != nil && !store.inFlight }
        assert(store.lastError == nil, store.lastError ?? "")
        assert(store.state.token.count == 64)
        let url = URL(string: origin + "/api/v1/leaderboard?search=" + name)!
        let (response, _) = try await URLSession.shared.data(from: url)
        let board = try JSONSerialization.jsonObject(with: response) as! [String: Any]
        let entry = (board["entries"] as! [[String: Any]])[0]
        assert(entry["tokens"] as! Int == 1_630_000)
        assert(abs((entry["costUsd"] as! Double) - 4.785) < 0.000001)
        // Removal requested while another write is queued/in flight must win.
        store.enable(name: name, website: origin, claude: .subscription, codex: .unclassified)
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
        let offline = LeaderboardStore(records: records.eraseToAnyPublisher(), stateURL: offlineURL)
        // With no records emitted to this new subscriber, opt-in is saved but no
        // upload starts. Removal must persist even with an unreachable server.
        offline.enable(name: "offline-fixture", website: "http://127.0.0.1:0", claude: .subscription, codex: .unclassified)
        offline.disable()
        try await wait { !offline.inFlight }
        let pending = try JSONDecoder().decode(LeaderboardState.self, from: Data(contentsOf: offlineURL))
        assert(!pending.enabled && pending.pendingRemoval && !pending.token.isEmpty)
        assert(offline.nextAttemptAt > Date(), "Failures must back off rather than retrying continuously")
        let restarted = LeaderboardStore(records: records.eraseToAnyPublisher(), stateURL: offlineURL)
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
