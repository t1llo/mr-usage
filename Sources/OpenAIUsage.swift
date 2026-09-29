// Live ChatGPT plan limits: the endpoint Codex's /status calls, authenticated with the access
// token Codex CLI stored in $CODEX_HOME/auth.json. Strictly read-only: refresh tokens are
// single-use, so refreshing here would log Codex out. When the token has expired the panel
// falls back to the last snapshot in Codex's logs until Codex refreshes it on its next run.
import Foundation

struct CodexAuth { let token: String; let account: String? }

enum CodexAuthError: LocalizedError {
    case expired
    var errorDescription: String? { "Codex login expired, run `codex` once" }
}

/// Nil when Codex is not signed in with ChatGPT (API-key logins have no plan limits), or keeps
/// its credentials in the Keychain instead of auth.json.
func readCodexAuth() throws -> CodexAuth? {
    let url = CodexScanner.home.appendingPathComponent("auth.json")
    guard let data = try? Data(contentsOf: url),
          let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let tokens = root["tokens"] as? [String: Any],
          let token = tokens["access_token"] as? String else { return nil }
    if let exp = jwtExpiry(token), exp < Date().addingTimeInterval(60) { throw CodexAuthError.expired }
    return CodexAuth(token: token, account: tokens["account_id"] as? String)
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

func fetchCodexLimits(_ auth: CodexAuth) async throws -> CodexLimits {
    var req = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!)
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
    return parseCodexUsage(json)
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
    return CodexLimits(asOf: now, usage: usage, plan: json["plan_type"] as? String, live: true)
}
