// ChatGPT plan limits and account usage: the endpoints Codex's /status and /usage call (live
// limits, past windows, daily tokens), authenticated with the access token Codex CLI
// ($CODEX_HOME/auth.json) or OpenCode (~/.local/share/opencode/auth.json) stored for the ChatGPT
// login. Strictly read-only: refresh tokens are single-use, so refreshing here
// would log those tools out. When both tokens have expired the panel falls back to the last
// snapshot in Codex's logs until one of them refreshes its token on its next run.
import Foundation

struct CodexAuth { let token: String; let account: String? }

enum CodexAuthError: LocalizedError {
    case expired
    var errorDescription: String? { "ChatGPT login expired, run Codex or OpenCode once" }
}

/// The first unexpired ChatGPT token, Codex's before OpenCode's. Nil when neither is signed in
/// with ChatGPT (API-key logins have no plan limits) or Codex keeps its login in the Keychain.
func readCodexAuth() throws -> CodexAuth? {
    let soon = Date().addingTimeInterval(60)
    var sawExpired = false
    for (token, account, expires) in [codexToken(), openCodeToken()].compactMap({ $0 }) {
        if (expires ?? jwtExpiry(token) ?? .distantFuture) < soon { sawExpired = true; continue }
        return CodexAuth(token: token, account: account)
    }
    if sawExpired { throw CodexAuthError.expired }
    return nil
}

private func json(at url: URL) -> [String: Any]? {
    (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
}

/// {"tokens": {"access_token", "account_id"}}.
private func codexToken() -> (String, String?, Date?)? {
    guard let t = json(at: CodexScanner.home.appendingPathComponent("auth.json"))?["tokens"] as? [String: Any],
          let access = t["access_token"] as? String else { return nil }
    return (access, t["account_id"] as? String, nil)
}

/// {"openai": {"type": "oauth", "access", "expires" (ms), "accountId"}}.
private func openCodeToken() -> (String, String?, Date?)? {
    guard let o = json(at: OpenCodeReader.dataDir.appendingPathComponent("auth.json"))?["openai"] as? [String: Any],
          o["type"] as? String == "oauth", let access = o["access"] as? String else { return nil }
    return (access, o["accountId"] as? String, (o["expires"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) })
}

/// The `exp` claim of a JWT, without verifying it; only used to avoid a request bound to fail.
private func jwtExpiry(_ jwt: String) -> Date? {
    let parts = jwt.split(separator: ".")
    guard parts.count == 3 else { return nil }
    var b64 = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    b64 += String(repeating: "=", count: (4 - b64.count % 4) % 4)
    guard let data = Data(base64Encoded: b64),
          let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let exp = claims["exp"] as? Double else { return nil }
    return Date(timeIntervalSince1970: exp)
}

/// GET chatgpt.com/backend-api/wham/<path> with the ChatGPT login, as Codex sends it.
private func chatGPTGet(_ path: String, _ auth: CodexAuth) async throws -> [String: Any] {
    var req = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/" + path)!)
    req.timeoutInterval = 10
    req.setValue("Bearer \(auth.token)", forHTTPHeaderField: "Authorization")
    if let a = auth.account { req.setValue(a, forHTTPHeaderField: "ChatGPT-Account-ID") }
    req.setValue("ClaudeUsageBar/0.3", forHTTPHeaderField: "User-Agent")
    let (data, resp) = try await URLSession.shared.data(for: req)
    let http = resp as? HTTPURLResponse
    if let code = http?.statusCode, code != 200 {
        if code == 401 { throw CodexAuthError.expired }
        throw FetchError.http(code, retryAfter: http?.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init),
                              message: nil)
    }
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw FetchError.badJSON }
    return json
}

func fetchCodexLimits(_ auth: CodexAuth) async throws -> CodexLimits {
    parseCodexUsage(try await chatGPTGet("usage", auth))
}

/// OpenAI usage credits, not dollars or Claude's extra-usage cents. Keep their own
/// capture time because a newer rate-limit snapshot can omit the credit balance.
struct CodexCredits {
    let asOf: Date
    let live: Bool
    let hasCredits: Bool
    let unlimited: Bool
    let balance: Double?

    var displayBalance: String {
        if unlimited { return "Unlimited" }
        guard let balance else { return hasCredits ? "Available" : "Unavailable" }
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 2
        return f.string(from: NSNumber(value: balance)) ?? String(balance)
    }
}

func parseCodexCredits(_ any: Any?, asOf: Date, live: Bool) -> CodexCredits? {
    guard let c = any as? [String: Any], let has = c["has_credits"] as? Bool,
          let unlimited = c["unlimited"] as? Bool else { return nil }
    let balance: Double?
    if let text = c["balance"] as? String {
        balance = Double(text.trimmingCharacters(in: .whitespacesAndNewlines))
    } else if let number = c["balance"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
        balance = number.doubleValue
    } else {
        balance = nil
    }
    return CodexCredits(asOf: asOf, live: live, hasCredits: has, unlimited: unlimited,
                        balance: balance.flatMap { $0.isFinite ? $0 : nil })
}

func parseCodexUsage(_ json: [String: Any], now: Date = Date()) -> CodexLimits {
    var usage = Usage()
    let rl = json["rate_limit"] as? [String: Any]
    for key in ["primary_window", "secondary_window"] {
        guard let w = rl?[key] as? [String: Any], let pct = w["used_percent"] as? Double else { continue }
        let secs = w["limit_window_seconds"] as? Double ?? 0
        let minutes = secs > 0 ? Int((secs + 59) / 60) : nil
        let reset = (w["reset_at"] as? Double).flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0) : nil }
        usage.limits.append(Limit(id: "codex_\(key)", label: windowLabel(minutes), pct: pct, resetsAt: reset,
                                  window: secs > 0 ? secs : nil))
    }
    return CodexLimits(asOf: now, usage: usage, plan: json["plan_type"] as? String, live: true,
                       credits: parseCodexCredits(json["credits"], asOf: now, live: true))
}

// MARK: - Plan history

/// One past or current window of the ChatGPT plan, as Codex's /usage shows it.
struct PlanPeriod: Identifiable {
    let id: String
    let start: Date
    let end: Date
    /// Share of the window's limit used, 0-100.
    let used: Double
    /// Same unit as `used`, largest first.
    let byModel: [(name: String, value: Double)]
}

struct PlanHistory {
    /// The server aggregates daily, so the current window lags the live limit by up to a day.
    let asOf: Date?
    /// Newest first.
    let periods: [PlanPeriod]
}

func fetchPlanHistory(_ auth: CodexAuth) async throws -> PlanHistory {
    parsePlanHistory(try await chatGPTGet("usage/plan_limit_history?days=30", auth))
}

/// Usage comes in basis points (1971.5 = 19.715% of the window's limit).
func parsePlanHistory(_ json: [String: Any]) -> PlanHistory {
    let periods: [PlanPeriod] = (json["periods"] as? [[String: Any]] ?? []).compactMap { p in
        guard let start = isoDate(p["starts_at"]), let end = isoDate(p["ends_at"]),
              let bp = p["used_basis_points"] as? Double else { return nil }
        let breakdowns = p["breakdowns"] as? [[String: Any]] ?? []
        let rows = breakdowns.first { $0["dimension"] as? String == "model" }?["rows"] as? [[String: Any]] ?? []
        let byModel = rows.compactMap { r -> (String, Double)? in
            guard let key = r["key"] as? String, let v = r["basis_points"] as? Double else { return nil }
            return (modelName(key), v / 100)
        }
        return PlanPeriod(id: p["id"] as? String ?? "\(start)", start: start, end: end, used: bp / 100,
                          byModel: byModel.sorted { $0.1 > $1.1 }.map { (name: $0.0, value: $0.1) })
    }
    return PlanHistory(asOf: isoDate(json["data_as_of"]), periods: periods.sorted { $0.start > $1.start })
}

// MARK: - Account activity

/// Token totals across every Codex surface, the overview in Codex's /usage.
struct AccountActivity {
    /// The day the server last aggregated; today is missing until it does.
    let asOf: Date?
    let lifetime: Double
    let peakDay: Double
    let currentStreak: Int
    let longestStreak: Int
    let chats: Int?
    /// The reasoning effort used most, with its share of turns (0-100).
    let effort: (name: String, share: Double)?
    /// Tokens per local calendar day, days without usage left out.
    let daily: [Date: Double]
    /// Each day's usage per model id. The server sends it relative to the busiest day, so only
    /// the shares mean anything.
    let modelDays: [Date: [String: Double]]
}

func fetchAccountActivity(_ auth: CodexAuth) async throws -> AccountActivity? {
    async let profile = chatGPTGet("profiles/me", auth)
    // Optional: without it the card just has no model split.
    async let breakdown = try? chatGPTGet("usage/daily-token-usage-breakdown", auth)
    return parseAccountActivity(try await profile, breakdown: await breakdown)
}

/// profiles/me: {"stats": {"lifetime_tokens", "daily_usage_buckets": [{"start_date", "tokens"}], ...},
/// "metadata": {"stats_as_of"}}. The breakdown: {"data": [{"date", "models": [{"model", "credits"}]}]}.
func parseAccountActivity(_ json: [String: Any], breakdown: [String: Any]?) -> AccountActivity? {
    guard let s = json["stats"] as? [String: Any], let lifetime = s["lifetime_tokens"] as? Double else { return nil }
    var daily: [Date: Double] = [:]
    for b in s["daily_usage_buckets"] as? [[String: Any]] ?? [] {
        if let d = calendarDay(b["start_date"]), let n = b["tokens"] as? Double { daily[d, default: 0] += n }
    }
    var modelDays: [Date: [String: Double]] = [:]
    for day in breakdown?["data"] as? [[String: Any]] ?? [] {
        guard let d = calendarDay(day["date"]) else { continue }
        for m in day["models"] as? [[String: Any]] ?? [] {
            // One row per model and speed; the speeds are summed.
            guard let id = m["model"] as? String, let v = m["credits"] as? Double, v > 0 else { continue }
            modelDays[d, default: [:]][id, default: 0] += v
        }
    }
    let effort = (s["most_used_reasoning_effort"] as? String).map {
        (name: $0, share: s["most_used_reasoning_effort_percentage"] as? Double ?? 0)
    }
    return AccountActivity(
        asOf: calendarDay((json["metadata"] as? [String: Any])?["stats_as_of"]),
        lifetime: lifetime, peakDay: s["peak_daily_tokens"] as? Double ?? 0,
        currentStreak: s["current_streak_days"] as? Int ?? 0, longestStreak: s["longest_streak_days"] as? Int ?? 0,
        chats: s["total_threads"] as? Int, effort: effort, daily: daily, modelDays: modelDays)
}

/// "2026-09-25" as the start of that day here, so it lines up with the chart's day buckets.
private func calendarDay(_ any: Any?) -> Date? {
    guard let s = any as? String else { return nil }
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd"
    return f.date(from: s)
}

/// How a token total divides into kinds, as fractions that add up to 1. The account only
/// reports totals, and the API price depends on the split, so the cost needs one.
struct TokenMix {
    let input, cacheRead, cacheWrite, output: Double

    /// A typical Codex session: each turn re-reads the conversation from the prompt cache, so
    /// about nine in ten tokens are cache reads and only a few percent are output.
    static let codex = TokenMix(input: 0.098, cacheRead: 0.882, cacheWrite: 0, output: 0.02)

    /// The split in these records; nil when there are too few tokens to go by.
    init?(_ records: [TokenRecord]) {
        let i = Double(records.reduce(0) { $0 + $1.input }), r = Double(records.reduce(0) { $0 + $1.cacheRead })
        let w = Double(records.reduce(0) { $0 + $1.cacheWrite }), o = Double(records.reduce(0) { $0 + $1.output })
        let total = i + r + w + o
        guard total >= 1_000_000 else { return nil }
        self.init(input: i / total, cacheRead: r / total, cacheWrite: w / total, output: o / total)
    }

    init(input: Double, cacheRead: Double, cacheWrite: Double, output: Double) {
        self.input = input; self.cacheRead = cacheRead; self.cacheWrite = cacheWrite; self.output = output
    }
}

/// One record per day and model: the day's tokens divided by each model's share of that day's
/// usage (all to "unknown" without a breakdown), then into kinds by `mix`.
func estimatedRecords(_ a: AccountActivity, mix: TokenMix) -> [TokenRecord] {
    a.daily.flatMap { day, tokens -> [TokenRecord] in
        let models = a.modelDays[day] ?? [:]
        let sum = models.values.reduce(0, +)
        let shares = sum > 0 ? models.mapValues { $0 / sum } : ["unknown": 1]
        return shares.map { name, share in
            let n = tokens * share
            let input = Int(n * mix.input), read = Int(n * mix.cacheRead)
            let write = Int(n * mix.cacheWrite), output = Int(n * mix.output)
            return TokenRecord(date: day, model: name, provider: .openai, source: .chatgpt,
                               input: input, output: output, cacheWrite: write, cacheRead: read,
                               cost: openAICost(model: name, input: input, output: output, cacheWrite: write, cacheRead: read))
        }
    }
}
