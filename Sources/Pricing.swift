// What Claude Code usage would cost at Anthropic's first-party API list prices, so the Tokens
// tab can show the value of a subscription. Prices are USD per million tokens, as published on
// 2026-09-25; update this table when they change.
import Foundation

struct Price {
    let input: Double
    let output: Double
    /// Cache reads are 0.1x input on most models, but cheaper on Claude Opus 5.5 and Fable 5.1.
    let cacheRead: Double
}

/// Keyed by model id without any date suffix. Models not listed here are left unpriced rather
/// than guessed, and the Tokens tab names them.
let apiPrices: [String: Price] = [
    "claude-fable-5-1": Price(input: 10, output: 50, cacheRead: 0.25),
    "claude-mythos-5-1": Price(input: 10, output: 50, cacheRead: 0.25),
    "claude-fable-5": Price(input: 10, output: 50, cacheRead: 1.00),
    "claude-mythos-5": Price(input: 10, output: 50, cacheRead: 1.00),
    "claude-opus-5-5": Price(input: 4, output: 20, cacheRead: 0.20),
    "claude-opus-5": Price(input: 5, output: 25, cacheRead: 0.50),
    "claude-opus-4-8": Price(input: 5, output: 25, cacheRead: 0.50),
    "claude-opus-4-7": Price(input: 5, output: 25, cacheRead: 0.50),
    "claude-opus-4-6": Price(input: 5, output: 25, cacheRead: 0.50),
    "claude-sonnet-5-5": Price(input: 2, output: 10, cacheRead: 0.20),
    "claude-sonnet-5": Price(input: 2, output: 10, cacheRead: 0.20),
    "claude-sonnet-4-6": Price(input: 3, output: 15, cacheRead: 0.30),
    "claude-haiku-4-5": Price(input: 1, output: 5, cacheRead: 0.10),
]

/// USD for one response, or nil for a model missing from the table. Cache writes are billed at
/// 1.25x input for the 5-minute cache and 2x for the 1-hour cache. Fast mode (Opus only) is 2x.
func apiCost(model: String, input: Int, output: Int, cacheWrite5m: Int, cacheWrite1h: Int,
             cacheRead: Int, fast: Bool) -> Double? {
    var id = model
    if let dash = id.lastIndex(of: "-"), id[id.index(after: dash)...].count == 8,
       Int(id[id.index(after: dash)...]) != nil { id = String(id[..<dash]) }
    guard let p = apiPrices[id] else { return nil }
    let usd = (Double(input) * p.input
        + Double(cacheWrite5m) * p.input * 1.25
        + Double(cacheWrite1h) * p.input * 2
        + Double(cacheRead) * p.cacheRead
        + Double(output) * p.output) / 1_000_000
    return fast ? usd * 2 : usd
}
