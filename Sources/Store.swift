// Polling state. Same schedule as before: every minute, doubling up to 10 minutes after a 429
// or 5xx, never faster than the server's Retry-After, and menu opens cannot bypass it.
import Foundation

@MainActor
final class Store: ObservableObject {
    @Published private(set) var usage: Usage?
    @Published private(set) var lastGoodAt: Date?
    @Published var lastError: String?
    @Published private(set) var inFlight = false

    /// Steady polling interval. Starts at one minute and grows after a 429; it does not shrink
    /// back, because the server has told us what cadence it tolerates.
    private var interval: TimeInterval = 60
    private(set) var nextFetchAt = Date.distantPast
    /// Claude Code rewrites the Keychain item when it refreshes the token. A read that lands in
    /// that window finds nothing, so remember the last token we saw and fall back to it.
    private var cachedToken: String?

    init() {
        fetch()
        Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    /// Fetch if the schedule says so. The timer, panel opens and the Refresh button all go
    /// through here, so none of them can exceed the current cadence.
    func tick() { if Date() >= nextFetchAt { fetch() } }

    private func fetch() {
        guard !inFlight else { return }
        inFlight = true
        nextFetchAt = Date().addingTimeInterval(interval)
        Task {
            defer { inFlight = false }
            do {
                if let fresh = await Task.detached(operation: readKeychainToken).value { cachedToken = fresh }
                guard let token = cachedToken else { throw FetchError.noToken }
                usage = try await fetchUsage(token: token)
                lastGoodAt = Date()
                lastError = nil
            } catch {
                lastError = error.localizedDescription
                if let fe = error as? FetchError, fe.isTransient {
                    // Slow down for good, and wait at least what the server asked for right now.
                    interval = min(interval * 2, 600)
                    nextFetchAt = Date().addingTimeInterval(max(interval, fe.retryAfter ?? 0))
                }
            }
        }
    }

    /// Menu bar text: session and weekly percentage, or "Claude" until the first load.
    var menuTitle: String {
        guard let u = usage, !u.limits.isEmpty else { return "Claude" }
        return u.limits.prefix(2).map { "\(Int($0.pct))%" }.joined(separator: " · ")
    }

    var status: String {
        var s: String
        if inFlight { s = "Refreshing…" }
        else if let e = lastError, let at = lastGoodAt { s = "Couldn't refresh: \(e). Showing \(clock(at)) data." }
        else if let e = lastError { s = "Couldn't load usage: \(e)." }
        else if let at = lastGoodAt { s = "Updated \(clock(at))" }
        else { s = "Loading…" }
        if lastError != nil, !inFlight { s += " Retrying at \(clock(nextFetchAt))." }
        return s
    }
}
