// Polling state. Same schedule as before: every minute, doubling up to 10 minutes after a 429
// or 5xx, never faster than the server's Retry-After, and menu opens cannot bypass it.
import Foundation

@MainActor
final class Store: ObservableObject {
    @Published private(set) var usage: Usage?
    @Published private(set) var lastGoodAt: Date?
    @Published var lastError: String?
    @Published private(set) var inFlight = false

    private let defaults: UserDefaults
    private var polling: ClaudePollingState
    var nextFetchAt: Date { polling.nextFetchAt }
    /// Claude Code rewrites the Keychain item when it refreshes the token. A read that lands in
    /// that window finds nothing, so remember the last token we saw and fall back to it.
    private var cachedToken: String?

    init(defaults: UserDefaults = .standard, startPolling: Bool = true) {
        self.defaults = defaults
        polling = ClaudePollingState.load(from: defaults)
        usage = polling.usage
        lastGoodAt = polling.lastGoodAt
        lastError = polling.lastFailure
        guard startPolling else { return }
        tick()
        Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    /// Fetch if the schedule says so. The timer, panel opens and the Refresh button all go
    /// through here, so none of them can exceed the current cadence.
    func tick() { if Date() >= nextFetchAt { fetch() } }

    private func fetch() {
        guard !inFlight, polling.begin(at: Date()) else { return }
        inFlight = true
        // Save the request gate before starting, so quitting/relaunching cannot bypass it.
        polling.save(to: defaults)
        Task {
            defer { polling.save(to: defaults); inFlight = false }
            do {
                if let fresh = await Task.detached(operation: readKeychainToken).value { cachedToken = fresh }
                guard let token = cachedToken else { throw FetchError.noToken }
                let fresh = try await fetchUsage(token: token)
                polling.succeeded(fresh, at: Date())
                usage = fresh
                lastGoodAt = polling.lastGoodAt
                lastError = nil
            } catch {
                lastError = error.localizedDescription
                polling.failed(error, at: Date())
            }
        }
    }

    var status: String {
        var s: String
        if inFlight { s = "Refreshing…" }
        else if lastError == "rate limited" {
            s = "Claude is temporarily rate limited."
            if let at = lastGoodAt { s += " Showing limits from \(resetClock(at))." }
        }
        else if let e = lastError, let at = lastGoodAt { s = "Couldn't refresh: \(e). Showing limits from \(resetClock(at))." }
        else if let e = lastError { s = "Couldn't load usage: \(e)." }
        else if let at = lastGoodAt { s = "Updated \(clock(at))" }
        else { s = "Loading…" }
        if lastError != nil, !inFlight { s += " Next automatic check: \(resetClock(nextFetchAt))." }
        return s
    }
}
