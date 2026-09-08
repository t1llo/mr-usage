// ClaudeUsageBar: a tiny macOS menu bar app that shows the same numbers as `/usage` in Claude Code.
// Data source: the usage endpoint Claude Code itself calls, authenticated with the OAuth token
// that `claude login` stored in the macOS Keychain. Nothing to configure.
import AppKit
import Security
import ServiceManagement

// MARK: - Model

struct Window { let label: String; let pct: Double; let resetsAt: Date? }
struct Credits { let usedCents: Double; let limitCents: Double? }
struct Usage { var windows: [Window] = []; var credits: Credits? }

enum FetchError: LocalizedError {
    case noToken
    case http(Int, retryAfter: TimeInterval?, message: String?)
    case badJSON
    var errorDescription: String? {
        switch self {
        case .noToken: return "not logged in, run `claude` and /login"
        case .http(401, _, _): return "login expired, open Claude Code once"
        case .http(429, _, let m): return "rate limited" + (m.map { " (\($0))" } ?? "")
        case .http(let code, _, let m): return "HTTP \(code)" + (m.map { " (\($0))" } ?? "")
        case .badJSON: return "unexpected response"
        }
    }
    var isTransient: Bool {
        if case .http(let code, _, _) = self { return code == 429 || code >= 500 }
        return false
    }
    var retryAfter: TimeInterval? {
        if case .http(_, let r, _) = self { return r }
        return nil
    }
}

// MARK: - Keychain + network

// Claude Code rewrites the Keychain item when it refreshes the token. A read that lands in that
// window finds nothing, so remember the last token we saw and fall back to it.
var cachedToken: String?

func accessToken() -> String? {
    let query: [CFString: Any] = [
        kSecClass: kSecClassGenericPassword,
        kSecAttrService: "Claude Code-credentials",
        kSecReturnData: true,
        kSecMatchLimit: kSecMatchLimitOne,
    ]
    var out: CFTypeRef?
    if SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
       let data = out as? Data,
       let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
       let oauth = root["claudeAiOauth"] as? [String: Any],
       let token = oauth["accessToken"] as? String {
        cachedToken = token
    }
    return cachedToken
}

func fetchUsage(_ done: @escaping (Result<Usage, Error>) -> Void) {
    guard let token = accessToken() else { return done(.failure(FetchError.noToken)) }
    var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
    req.timeoutInterval = 10
    req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.setValue("ClaudeUsageBar/0.1", forHTTPHeaderField: "User-Agent")
    URLSession.shared.dataTask(with: req) { data, resp, err in
        let result: Result<Usage, Error>
        let http = resp as? HTTPURLResponse
        let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        if let err {
            result = .failure(err)
        } else if let code = http?.statusCode, code != 200 {
            let retry = http?.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init)
            let message = (json?["error"] as? [String: Any])?["message"] as? String
            result = .failure(FetchError.http(code, retryAfter: retry, message: message))
        } else if let json {
            result = .success(parse(json))
        } else {
            result = .failure(FetchError.badJSON)
        }
        DispatchQueue.main.async { done(result) }
    }.resume()
}

func parse(_ json: [String: Any]) -> Usage {
    var usage = Usage()
    let keys: [(String, String)] = [
        ("five_hour", "Session"),
        ("seven_day", "Week (all models)"),
        ("seven_day_sonnet", "Week (Sonnet)"),
        ("seven_day_opus", "Week (Opus)"),
    ]
    for (key, label) in keys {
        guard let d = json[key] as? [String: Any], let pct = d["utilization"] as? Double else { continue }
        usage.windows.append(Window(label: label, pct: pct, resetsAt: isoDate(d["resets_at"])))
    }
    if let e = json["extra_usage"] as? [String: Any], e["is_enabled"] as? Bool == true,
       let used = e["used_credits"] as? Double {
        usage.credits = Credits(usedCents: used, limitCents: e["monthly_limit"] as? Double)
    }
    return usage
}

func isoDate(_ any: Any?) -> Date? {
    guard let s = any as? String else { return nil }
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = f.date(from: s) { return d }
    f.formatOptions = [.withInternetDateTime]
    return f.date(from: s)
}

// MARK: - Formatting

func resetText(_ date: Date?) -> String {
    guard let date else { return "" }
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US")
    let time = Calendar.current.component(.minute, from: date) == 0 ? "ha" : "h:mma"
    if Calendar.current.isDateInToday(date) { f.dateFormat = time }
    else if date.timeIntervalSinceNow < 6 * 86_400 { f.dateFormat = "EEE \(time)" }
    else { f.dateFormat = "MMM d" }
    return "Resets " + f.string(from: date).replacingOccurrences(of: "AM", with: "am").replacingOccurrences(of: "PM", with: "pm")
}

func firstOfNextMonth() -> String {
    var c = Calendar.current.dateComponents([.year, .month], from: Date())
    c.month! += 1; c.day = 1
    let f = DateFormatter(); f.locale = Locale(identifier: "en_US"); f.dateFormat = "MMM d"
    return f.string(from: Calendar.current.date(from: c)!)
}

func clock(_ d: Date) -> String {
    let f = DateFormatter(); f.timeStyle = .short; f.dateStyle = .none
    return f.string(from: d)
}

func money(_ cents: Double) -> String { String(format: "$%.2f", cents / 100) }

// MARK: - Menu row: label + percentage, native progress bar, caption

final class RowView: NSView {
    static let width: CGFloat = 260
    let title = NSTextField(labelWithString: "")
    let pct = NSTextField(labelWithString: "")
    let bar = NSProgressIndicator()
    let caption = NSTextField(labelWithString: "")

    init(_ label: String, _ percent: Double, _ sub: String) {
        super.init(frame: NSRect(x: 0, y: 0, width: RowView.width, height: 58))
        let inset: CGFloat = 14, w = RowView.width - 2 * inset
        title.font = .systemFont(ofSize: 13, weight: .medium)
        title.frame = NSRect(x: inset, y: 37, width: w - 56, height: 17)
        title.stringValue = label
        pct.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        pct.alignment = .right
        pct.frame = NSRect(x: inset + w - 56, y: 37, width: 56, height: 17)
        pct.stringValue = "\(Int(percent))%"
        bar.style = .bar
        bar.isIndeterminate = false
        bar.controlSize = .small
        bar.minValue = 0; bar.maxValue = 100
        bar.doubleValue = min(100, max(0, percent))
        bar.frame = NSRect(x: inset, y: 22, width: w, height: 12)
        caption.font = .systemFont(ofSize: 11)
        caption.textColor = .secondaryLabelColor
        caption.frame = NSRect(x: inset, y: 4, width: w, height: 15)
        caption.stringValue = sub
        [title, pct, bar, caption].forEach(addSubview)
    }
    required init?(coder: NSCoder) { fatalError() }
}

// MARK: - App

final class App: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let menu = NSMenu()

    var lastGood: Usage?
    var lastGoodAt: Date?
    var lastError: String?
    var inFlight = false

    /// Steady polling interval. Starts at one minute and grows after a 429; it does not shrink
    /// back, because the server has told us what cadence it tolerates.
    var interval: TimeInterval = 60
    var nextFetchAt = Date.distantPast

    func applicationDidFinishLaunching(_: Notification) {
        // Refuse to run twice: a second instance would double the request rate.
        let me = Bundle.main.bundleIdentifier ?? "local.tillobeffa.ClaudeUsageBar"
        if NSRunningApplication.runningApplications(withBundleIdentifier: me).count > 1 {
            NSApp.terminate(nil)
            return
        }
        item.button?.title = "Claude"
        item.button?.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        menu.delegate = self
        item.menu = menu
        fetch()
        Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in self?.tick() }
    }

    func menuWillOpen(_: NSMenu) { tick(); render() }

    /// Fetch if the schedule says so. Both the timer and menu opens go through here, so neither
    /// can exceed the current cadence.
    func tick() { if Date() >= nextFetchAt { fetch() } }

    @objc func refreshClicked() { tick() }

    func fetch() {
        guard !inFlight else { return }
        inFlight = true
        nextFetchAt = Date().addingTimeInterval(interval)
        fetchUsage { [weak self] result in
            guard let self else { return }
            self.inFlight = false
            switch result {
            case .success(let usage):
                self.lastGood = usage
                self.lastGoodAt = Date()
                self.lastError = nil
            case .failure(let error):
                self.lastError = error.localizedDescription
                if let fe = error as? FetchError, fe.isTransient {
                    // Slow down for good, and wait at least what the server asked for right now.
                    self.interval = min(self.interval * 2, 600)
                    let wait = max(self.interval, fe.retryAfter ?? 0)
                    self.nextFetchAt = Date().addingTimeInterval(wait)
                }
            }
            self.render()
        }
    }

    func render() {
        menu.removeAllItems()
        if let u = lastGood {
            item.button?.title = u.windows.prefix(2).map { "\(Int($0.pct))%" }.joined(separator: " · ")
            for w in u.windows { addRow(w.label, w.pct, resetText(w.resetsAt)) }
            if let c = u.credits {
                let pct = (c.limitCents ?? 0) > 0 ? c.usedCents / c.limitCents! * 100 : 0
                let limit = c.limitCents.map(money) ?? "no limit"
                addRow("Extra usage", pct, "\(money(c.usedCents)) / \(limit) · Resets \(firstOfNextMonth())")
            }
        } else {
            item.button?.title = "Claude"
        }

        var status: String
        if inFlight { status = "Refreshing…" }
        else if let e = lastError, let at = lastGoodAt { status = "Couldn't refresh: \(e). Showing \(clock(at)) data." }
        else if let e = lastError { status = "Couldn't load usage: \(e)." }
        else if let at = lastGoodAt { status = "Updated \(clock(at))" }
        else { status = "Loading…" }
        if lastError != nil, !inFlight { status += " Retrying at \(clock(nextFetchAt))." }
        addNote(status)

        menu.addItem(.separator())
        let r = NSMenuItem(title: "Refresh", action: #selector(refreshClicked), keyEquivalent: "r"); r.target = self
        menu.addItem(r)
        let login = NSMenuItem(title: "Open at Login", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    func addRow(_ label: String, _ pct: Double, _ caption: String) {
        let mi = NSMenuItem()
        mi.view = RowView(label, pct, caption)
        menu.addItem(mi)
    }

    func addNote(_ text: String) {
        let mi = NSMenuItem()
        mi.isEnabled = false
        mi.attributedTitle = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
        menu.addItem(mi)
    }

    @objc func toggleLogin(_ sender: NSMenuItem) {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
            sender.state = SMAppService.mainApp.status == .enabled ? .on : .off
        } catch {
            lastError = "login item: \(error.localizedDescription)"
            render()
        }
    }
}

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
