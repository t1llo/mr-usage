// The Tokens tab: tokens per hour or day as a bar chart, totals as tiles, split by model.
import Charts
import SwiftUI

extension TokenMetric {
    func color(_ t: Theme) -> Color {
        switch self {
        case .cost: return t.accent
        case .input: return t.blue
        case .output: return t.cyan
        case .cacheWrite: return t.orange
        case .cacheRead: return t.teal
        }
    }
    var icon: String {
        switch self {
        case .cost: return "dollarsign.circle.fill"
        case .input: return "arrow.down.circle.fill"
        case .output: return "arrow.up.circle.fill"
        case .cacheWrite: return "square.and.arrow.down.fill"
        case .cacheRead: return "arrow.triangle.2.circlepath.circle.fill"
        }
    }
    func help(_ p: Provider) -> String {
        switch self {
        case .cost: return p == .claude
            ? "What these tokens would cost at Anthropic API list prices, cache and fast mode included"
            : "What these tokens would cost at OpenAI API list prices (Standard tier), cache included"
        case .input: return "Uncached input tokens sent to the model"
        case .output: return "Tokens the model generated, reasoning included"
        case .cacheWrite: return "Input tokens written to the prompt cache"
        case .cacheRead: return "Input tokens served from the prompt cache"
        }
    }
}

/// Where the OpenAI Tokens tab reads from: the ChatGPT account (every device, daily) or the
/// logs on this Mac (per request, exact split).
enum OpenAISource: String, CaseIterable {
    case account = "All devices", mac = "This Mac"
}

struct TokensView: View {
    @ObservedObject var tokens: TokenStore
    let provider: Provider
    @AppStorage("tokenRange") private var range: TokenRange = .week
    @AppStorage("tokenMetric") private var metric: TokenMetric = .cost
    @AppStorage("openAISource") private var source: OpenAISource = .account
    @State private var hovered: Date?
    @Environment(\.theme) private var t

    var body: some View {
        let hasLocal = tokens.records.contains { $0.provider == provider }
        let hasAccount = provider == .openai && tokens.activity != nil
        let account = hasAccount && (source == .account || !hasLocal)
        VStack(alignment: .leading, spacing: 10) {
            if hasAccount && hasLocal {
                Segmented(options: OpenAISource.allCases, selection: $source) { $0.rawValue }
            }
            if account { content(account: true) }
            else if tokens.loaded && !hasLocal { empty }
            else { content(account: false) }
        }
    }

    /// The account is aggregated by day, so it has no 24-hour view.
    private func ranges(_ account: Bool) -> [TokenRange] { account ? [.week, .month] : TokenRange.allCases }
    private func shown(_ account: Bool) -> TokenRange { account && range == .day ? .week : range }
    /// Nothing logged for this provider inside the 30-day horizon: say why instead of drawing
    /// an empty chart that looks broken.
    private var empty: some View {
        VStack(spacing: 10) {
            Card {
                VStack(spacing: 8) {
                    Image(systemName: "chart.bar.xaxis").font(.title3).foregroundStyle(t.muted)
                    Text(emptyText)
                        .font(.callout).foregroundStyle(t.subtext)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, minHeight: 110)
            }
            Text(footnote(nil)).font(.caption2).foregroundStyle(t.muted).frame(maxWidth: .infinity)
        }
    }

    private var emptyText: String {
        let has = tokens.sources.contains
        switch provider {
        case .claude:
            return "No Claude usage in the last 30 days. Counts appear after your next Claude Code or OpenCode request."
        case .openai:
            if tokens.planHistory != nil || tokens.activity != nil {
                return "Token counts by type and API cost come from Codex and OpenCode logs on this Mac, and there are none from the last 30 days yet. Codex writes its log once you send a message."
            }
            if has(.codex) { return "No Codex requests in the last 30 days. Counts appear after your next message in Codex." }
            return "No usage yet. Token counts come from Codex's session logs, which Codex writes once you send a message"
                + (has(.opencode) ? ", and from OpenAI messages in OpenCode (none in the last 30 days)." : ".")
        }
    }

    private func content(account: Bool) -> some View {
        let r = shown(account)
        let s = tokens.summary(provider, account: account, range: r, metric: metric)
        let est = account ? "est." : nil
        return VStack(alignment: .leading, spacing: 10) {
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline) {
                        readout(s, range: r, account: account)
                        Spacer()
                        Segmented(options: ranges(account), selection: Binding(get: { r }, set: { range = $0 })) { $0.rawValue }
                    }
                    if tokens.loaded || account { chart(s, range: r, account: account) } else {
                        ProgressView().controlSize(.small).frame(maxWidth: .infinity, minHeight: 120)
                    }
                }
            }
            MetricTile(metric: .cost, value: s.totals[.cost] ?? 0, selected: metric == .cost,
                       caption: account ? "estimated at API prices" : "if billed at API prices",
                       help: account ? costHelp : metric.help(provider)) { metric = .cost }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                ForEach(TokenMetric.tokenKinds) { m in
                    MetricTile(metric: m, value: s.totals[m] ?? 0, selected: m == metric, caption: est,
                               help: m.help(provider) + (account ? ". Estimated: the account only reports totals." : "")) { metric = m }
                }
            }
            if !s.byModel.isEmpty { Card { ModelList(rows: s.byModel, metric: metric) } }
            if account, let a = tokens.activity { AccountStats(activity: a) }
            if metric == .cost, !s.unpriced.isEmpty {
                Text("No API price for \(s.unpriced.sorted().joined(separator: ", ")), left out of the cost")
                    .font(.caption2).foregroundStyle(t.warn)
                    .frame(maxWidth: .infinity)
            }
            Text(account ? accountNote : footnote(Set(tokens.records.filter { $0.provider == provider }.map(\.source))))
                .font(.caption2).foregroundStyle(t.muted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        }
    }

    private var costHelp: String {
        "What these tokens would cost at OpenAI API list prices (Standard tier). The account reports "
            + "total tokens per day and model; the split into input, cache and output is "
            + (tokens.mixFromLogs ? "taken from this Mac's Codex logs." : "a typical Codex session's (88% cache reads, 10% input, 2% output).")
    }

    private var accountNote: String {
        "All devices, by UTC day. Local Codex/OpenCode logs fill unreported days without double-counting. Account split and cost estimated from "
            + (tokens.mixFromLogs ? "this Mac's Codex logs." : "a typical Codex session.")
    }

    /// Which tools the numbers come from, or where they would come from.
    private func footnote(_ used: Set<Source>?) -> String {
        let tools: [Source] = provider == .claude ? [.claudeCode, .opencode] : [.codex, .opencode]
        let found = tools.filter { used?.contains($0) ?? false }
        if found.isEmpty { return "Reads \(tools.map(\.rawValue).joined(separator: " and ")) logs on this Mac" }
        return "From \(found.map(\.rawValue).joined(separator: " and ")) sessions on this Mac"
    }

    /// Hovered bucket's value, or the range total for the selected metric.
    private func readout(_ s: TokenSummary, range: TokenRange, account: Bool) -> some View {
        let b = hovered.flatMap { h in s.buckets.first { $0.start == h } }
        return VStack(alignment: .leading, spacing: 1) {
            Text(metric.format(b?.value ?? s.totals[metric] ?? 0))
                .font(.system(size: 20, weight: .bold, design: .rounded).monospacedDigit())
                .contentTransition(.numericText())
            Text("\(metric == .cost ? "API cost" : metric.rawValue.lowercased()) · \(b.map { bucketLabel($0.start, range: range, account: account) } ?? "last \(range.rawValue)")")
                .font(.caption).foregroundStyle(t.muted)
        }
    }

    private func bucketLabel(_ d: Date, range: TokenRange, account: Bool) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US")
        if account { f.timeZone = usageUTCCalendar.timeZone }
        f.dateFormat = range == .day ? "EEE ha" : "EEE MMM d"
        return f.string(from: d).replacingOccurrences(of: "AM", with: "am").replacingOccurrences(of: "PM", with: "pm")
    }

    private func chart(_ s: TokenSummary, range: TokenRange, account: Bool) -> some View {
        Chart(s.buckets) { b in
            BarMark(x: .value("Time", b.start, unit: range.unit), y: .value("Tokens", b.value))
                .foregroundStyle(metric.color(t))
                .cornerRadius(2)
                .opacity(hovered == nil || hovered == b.start ? 1 : 0.4)
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { v in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3])).foregroundStyle(t.border)
                AxisValueLabel { if let n = v.as(Double.self) { Text(metric == .cost ? "$" + compact(n) : compact(n)).foregroundStyle(t.muted) } }
            }
        }
        .chartXAxis {
            switch range {
            case .day: AxisMarks(values: .stride(by: .hour, count: 6)) { _ in AxisValueLabel(format: .dateTime.hour()).foregroundStyle(t.muted) }
            case .week: AxisMarks(values: .stride(by: .day)) { _ in AxisValueLabel(format: .dateTime.weekday(.narrow), centered: true).foregroundStyle(t.muted) }
            case .month: AxisMarks(values: .stride(by: .day, count: 7)) { _ in AxisValueLabel(format: .dateTime.month(.abbreviated).day()).foregroundStyle(t.muted) }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { g in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        guard case .active(let p) = phase,
                              let d: Date = proxy.value(atX: p.x - g[proxy.plotAreaFrame].origin.x)
                        else { hovered = nil; return }
                        hovered = (account ? usageUTCCalendar : Calendar.current).dateInterval(of: range.unit, for: d)?.start
                    }
            }
        }
        .frame(height: 120)
        .environment(\.timeZone, account ? usageUTCCalendar.timeZone : .current)
        .animation(.easeOut(duration: 0.4), value: metric)
        .animation(.easeOut(duration: 0.4), value: range)
    }
}

/// One total; clicking it switches the chart and model list to that metric.
struct MetricTile: View {
    let metric: TokenMetric
    let value: Double
    let selected: Bool
    var caption: String?
    let help: String
    let action: () -> Void
    @Environment(\.theme) private var t

    var body: some View {
        let c = metric.color(t)
        Button(action: action) {
            VStack(alignment: .leading, spacing: 3) {
                Label(metric.rawValue, systemImage: metric.icon)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(selected ? c : t.muted)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(metric.format(value))
                        .font(.system(size: 15, weight: .semibold, design: .rounded).monospacedDigit())
                        .contentTransition(.numericText())
                    if let caption { Text(caption).font(.caption).foregroundStyle(t.muted) }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(selected ? c.opacity(0.14) : t.card))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(selected ? c.opacity(0.6) : t.border.opacity(0.6), lineWidth: 0.75))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

struct ModelList: View {
    let rows: [(name: String, value: Double)]
    let metric: TokenMetric
    @Environment(\.theme) private var t

    var body: some View {
        let top = rows.prefix(4)
        let total = max(0.000_001, rows.reduce(0) { $0 + $1.value })
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(top), id: \.name) { r in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(r.name).font(.system(size: 12, weight: .medium))
                        Spacer()
                        Text("\(metric.format(r.value)) · \(Int((r.value / total * 100).rounded()))%")
                            .font(.system(size: 12, design: .rounded).monospacedDigit())
                            .foregroundStyle(t.muted)
                    }
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(t.track)
                            Capsule().fill(metric.color(t))
                                .frame(width: max(4, g.size.width * r.value / total))
                        }
                    }
                    .frame(height: 4)
                }
            }
        }
    }
}

/// The ChatGPT plan's recent windows, as Codex's /usage shows them. Click a window to see which
/// models used it. Covers every surface (Codex CLI, IDE, cloud, OpenCode), unlike the token counts.
struct PlanHistoryCard: View {
    let history: PlanHistory
    @State private var selected: String?
    @Environment(\.theme) private var t

    var body: some View {
        let now = Date()
        let chosen = history.periods.first { $0.id == selected } ?? history.periods[0]
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("Plan usage", systemImage: "calendar")
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(t.subtext)
                    Spacer()
                    if let d = history.asOf { Text("as of \(day(d))").font(.caption).foregroundStyle(t.muted) }
                }
                ForEach(history.periods.prefix(5)) { p in
                    Button { withAnimation(.easeOut(duration: 0.2)) { selected = p.id } } label: {
                        row(p, current: p.end > now, chosen: p.id == chosen.id)
                    }
                    .buttonStyle(.plain)
                }
                if !chosen.byModel.isEmpty {
                    Rectangle().fill(t.border.opacity(0.6)).frame(height: 0.5)
                    Text("By model, \(range(chosen))").font(.caption).foregroundStyle(t.muted)
                    ForEach(chosen.byModel.prefix(4), id: \.name) { m in
                        HStack {
                            Text(m.name).font(.system(size: 12, weight: .medium))
                            Spacer()
                            Text(pct(m.value)).font(.system(size: 12, design: .rounded).monospacedDigit())
                                .foregroundStyle(t.muted)
                        }
                    }
                }
            }
        }
        .help("Share of each window's limit used, across Codex CLI, IDE, cloud and OpenCode. Updated daily by OpenAI.")
    }

    private func row(_ p: PlanPeriod, current: Bool, chosen: Bool) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(range(p)).font(.system(size: 12, weight: chosen ? .semibold : .regular))
                if current {
                    Text("Now").font(.caption2.weight(.semibold)).foregroundStyle(t.accent)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(t.accent.opacity(0.14)))
                }
                Spacer()
                Text(pct(p.used)).font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(t.track)
                    Capsule().fill(t.level(p.used))
                        .frame(width: p.used > 0 ? max(4, g.size.width * min(1, p.used / 100)) : 0)
                }
            }
            .frame(height: 5)
        }
        .padding(.horizontal, 6).padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(chosen ? t.accent.opacity(0.08) : .clear))
        .contentShape(Rectangle())
    }

    /// "Sep 19 to Sep 26", or "Sep 26, 11:46am to 4:57pm" for a window that ended early.
    private func range(_ p: PlanPeriod) -> String {
        let cal = Calendar.current
        if cal.isDate(p.start, inSameDayAs: p.end) { return "\(day(p.start)), \(time(p.start)) to \(time(p.end))" }
        return "\(day(p.start)) to \(day(p.end))"
    }

    private func day(_ d: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US"); f.dateFormat = "MMM d"
        return f.string(from: d)
    }

    private func time(_ d: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US"); f.dateFormat = "h:mma"
        return f.string(from: d).replacingOccurrences(of: "AM", with: "am").replacingOccurrences(of: "PM", with: "pm")
    }

    private func pct(_ v: Double) -> String { v > 0 && v < 1 ? "<1%" : "\(Int(v.rounded()))%" }
}

/// The account's lifetime numbers, as the overview in Codex's /usage shows them.
struct AccountStats: View {
    let activity: AccountActivity
    @Environment(\.theme) private var t

    var body: some View {
        Card {
            HStack(alignment: .top, spacing: 0) {
                stat("Lifetime", compact(activity.lifetime), "tokens")
                stat("Peak day", compact(activity.peakDay), "tokens")
                stat("Streak", "\(activity.currentStreak)d", "best \(activity.longestStreak)d")
                if let c = activity.chats { stat("Chats", "\(c)", "all time") }
            }
        }
        .help(activity.effort.map { "Mostly \($0.name) reasoning (\(Int($0.share.rounded()))% of turns)" } ?? "")
    }

    private func stat(_ label: String, _ value: String, _ caption: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 11, weight: .medium)).foregroundStyle(t.muted)
            Text(value).font(.system(size: 15, weight: .semibold, design: .rounded).monospacedDigit())
            Text(caption).font(.caption2).foregroundStyle(t.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
