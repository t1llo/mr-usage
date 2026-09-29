// Data layer: read Claude Code's OAuth token, call the usage endpoint `/usage` uses, parse it.
import Foundation

struct Limit: Identifiable {
    let id: String
    let label: String
    let pct: Double
    let resetsAt: Date?
}
struct Credits { let usedCents: Double; let limitCents: Double? }
struct Usage { var limits: [Limit] = []; var credits: Credits? }

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

/// Reads the token through `/usr/bin/security` instead of SecItemCopyMatching.
///
/// Claude Code writes its "Claude Code-credentials" item with the `security` tool, so that tool
/// is on the item's access list. It rewrites the item every time it refreshes the token, which
/// resets the list and throws away any "Always Allow" granted to this app. Asking `security`
/// to read it avoids both the first prompt and the prompt that used to come back after every
/// token refresh. Blocking; call it off the main thread.
func readKeychainToken() -> String? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
    p.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
    let out = Pipe()
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return nil }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    guard p.terminationStatus == 0,
          let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
          let root = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
          let oauth = root["claudeAiOauth"] as? [String: Any]
    else { return nil }
    return oauth["accessToken"] as? String
}

func fetchUsage(token: String) async throws -> Usage {
    var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
    req.timeoutInterval = 10
    req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.setValue("ClaudeUsageBar/0.2", forHTTPHeaderField: "User-Agent")
    let (data, resp) = try await URLSession.shared.data(for: req)
    let http = resp as? HTTPURLResponse
    let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    if let code = http?.statusCode, code != 200 {
        let retry = http?.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init)
        let message = (json?["error"] as? [String: Any])?["message"] as? String
        throw FetchError.http(code, retryAfter: retry, message: message)
    }
    guard let json else { throw FetchError.badJSON }
    return parse(json)
}

func parse(_ json: [String: Any]) -> Usage {
    var usage = Usage()
    let keys: [(String, String)] = [
        ("five_hour", "Session"),
        ("seven_day", "Week"),
        ("seven_day_sonnet", "Week · Sonnet"),
        ("seven_day_opus", "Week · Opus"),
    ]
    for (key, label) in keys {
        guard let d = json[key] as? [String: Any], let pct = d["utilization"] as? Double else { continue }
        usage.limits.append(Limit(id: key, label: label, pct: pct, resetsAt: isoDate(d["resets_at"])))
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

/// "in 2h 14m", "in 3d 4h", "in 12m".
func countdown(to date: Date?, now: Date = Date()) -> String {
    guard let date else { return "" }
    let mins = max(0, Int(date.timeIntervalSince(now) / 60))
    let d = mins / 1440, h = (mins % 1440) / 60, m = mins % 60
    if d > 0 { return "in \(d)d \(h)h" }
    if h > 0 { return "in \(h)h \(m)m" }
    return "in \(m)m"
}

/// "3:40pm", "Thu 9am", "Oct 4".
func resetClock(_ date: Date?) -> String {
    guard let date else { return "" }
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US")
    let time = Calendar.current.component(.minute, from: date) == 0 ? "ha" : "h:mma"
    if Calendar.current.isDateInToday(date) { f.dateFormat = time }
    else if date.timeIntervalSinceNow < 6 * 86_400 { f.dateFormat = "EEE \(time)" }
    else { f.dateFormat = "MMM d" }
    return f.string(from: date).replacingOccurrences(of: "AM", with: "am").replacingOccurrences(of: "PM", with: "pm")
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
