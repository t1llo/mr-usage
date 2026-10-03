// The Tokens tab: softly shaded activity charts, quiet totals, and a per-model breakdown.
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
    func help(_ p: Provider) -> String {
        switch self {
        case .cost: return p == .claude
            ? "What these tokens would cost at Anthropic API list prices, cache and fast mode included"
            : "What these tokens would cost at OpenAI API list prices (Standard tier), cache included"
        case .input: return "New input not served from or written to the prompt cache. Total prompt input also includes cache reads and writes."
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
    @Environment(\.theme) private var t

    var body: some View {
        let hasLocal = !(tokens.providerSources[provider] ?? []).isEmpty
        let hasAccount = provider == .openai && tokens.activity != nil
        let account = hasAccount && (source == .account || !hasLocal)
        VStack(alignment: .leading, spacing: 12) {
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
        let totals = tokens.summary(provider, account: account, range: r, metric: .cost).totals
        let kinds = TokenMetric.tokenKinds.filter { $0 != .cacheWrite || provider == .claude || (totals[.cacheWrite] ?? 0) > 0 }
        let selected = metric == .cacheWrite && !kinds.contains(.cacheWrite) ? TokenMetric.input : metric
        let s = tokens.summary(provider, account: account, range: r, metric: selected)
        let est = account ? "est." : nil
        return VStack(alignment: .leading, spacing: 12) {
            TokenChartCard(summary: s, metric: selected,
                           range: Binding(get: { r }, set: { range = $0 }), ranges: ranges(account),
                           account: account, loading: !tokens.loaded && !account)
                .id("\(provider.rawValue)/\(account)")
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    MetricTile(metric: .cost, value: s.totals[.cost] ?? 0, selected: metric == .cost,
                               caption: account ? "Estimated at API prices" : "If billed at API prices",
                               help: account ? costHelp : TokenMetric.cost.help(provider)) { metric = .cost }
                    Rectangle().fill(t.border.opacity(0.6)).frame(height: 0.5)
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 6) {
                        ForEach(kinds) { m in
                            MetricTile(metric: m, value: s.totals[m] ?? 0, selected: m == selected, caption: est,
                                       help: m.help(provider) + (account ? ". Estimated: the account only reports totals." : "")) { metric = m }
                        }
                    }
                }
            }
            if provider == .claude {
                Text("Prompt input: \(compact((s.totals[.input] ?? 0) + (s.totals[.cacheRead] ?? 0) + (s.totals[.cacheWrite] ?? 0))) total. Cache reads and writes are input too; repeated cached context can dwarf new input and output.")
                    .font(.system(size: 10)).foregroundStyle(t.muted)
                    .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 4)
            }
            if !s.byModel.isEmpty { Card { ModelList(rows: s.byModel, metric: selected) } }
            if account, let a = tokens.activity { AccountStats(activity: a) }
            if metric == .cost, !s.unpriced.isEmpty {
                Text("No API price for \(s.unpriced.sorted().joined(separator: ", ")), left out of the cost")
                    .font(.system(size: 10)).foregroundStyle(t.warn)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(account ? accountNote : footnote(tokens.providerSources[provider]))
                .font(.system(size: 10)).foregroundStyle(t.muted)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)
        }
    }

    private var costHelp: String {
        "What these tokens would cost at OpenAI API list prices (Standard tier). The account reports "
            + "total tokens per day and model; the split into input, cache and output is "
            + (tokens.mixFromLogs ? "taken from this Mac's Codex/OpenCode logs." : "a typical Codex session's (88% cache reads, 10% input, 2% output).")
    }

    private var accountNote: String {
        "All devices, by UTC day. Local Codex/OpenCode logs fill unreported days without double-counting. Account split and cost estimated from "
            + (tokens.mixFromLogs ? "this Mac's Codex/OpenCode logs." : "a typical Codex session.")
    }

    /// Which tools the numbers come from, or where they would come from.
    private func footnote(_ used: Set<Source>?) -> String {
        let tools: [Source] = provider == .claude ? [.claudeCode, .opencode] : [.codex, .opencode]
        let found = tools.filter { used?.contains($0) ?? false }
        if found.isEmpty { return "Reads \(tools.map(\.rawValue).joined(separator: " and ")) logs on this Mac" }
        return "From \(found.map(\.rawValue).joined(separator: " and ")) sessions on this Mac"
    }
}

/// Data-only chart surface. Each point is one complete hourly or daily bucket, including zeroes.
struct TokenChartCard: View {
    let summary: TokenSummary
    let metric: TokenMetric
    @Binding var range: TokenRange
    let ranges: [TokenRange]
    let account: Bool
    var loading = false
    @State private var hovered: Date?
    @Environment(\.theme) private var t
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(metric == .cost ? "API equivalent" : metric.label)
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(t.subtext)
                    Spacer(minLength: 8)
                    Segmented(options: ranges, selection: $range) { $0.rawValue }
                }
                readout
                if loading {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity, minHeight: 108)
                } else {
                    chart
                }
            }
        }
        .onChange(of: range) { _ in hovered = nil }
    }

    /// Hovered bucket's value, or the range total for the selected metric.
    private var readout: some View {
        let b = hovered.flatMap { h in summary.buckets.first { $0.start == h } }
        return VStack(alignment: .leading, spacing: 4) {
            Text(metric.format(b?.value ?? summary.totals[metric] ?? 0))
                .font(.system(size: 30, weight: .semibold).monospacedDigit())
                .tracking(-0.8)
                .lineLimit(1).minimumScaleFactor(0.7)
                .contentTransition(.numericText())
            Text((b.map { bucketLabel($0.start) } ?? "Last \(range.rawValue)")
                 + (account ? " · estimated" : metric == .cost ? " · at API prices" : " · tokens"))
                .font(.system(size: 10)).foregroundStyle(t.muted)
        }
    }

    private func bucketLabel(_ d: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US")
        if account { f.timeZone = usageUTCCalendar.timeZone }
        f.dateFormat = range == .day ? "EEE ha" : "EEE MMM d"
        return f.string(from: d).replacingOccurrences(of: "AM", with: "am").replacingOccurrences(of: "PM", with: "pm")
    }

    private var chart: some View {
        let color = metric.color(t)
        let valueLabel = metric == .cost ? "API-equivalent cost" : "Tokens"
        return Chart {
            ForEach(summary.buckets) { b in
                AreaMark(x: .value("Time", b.start, unit: range.unit), y: .value(valueLabel, b.value))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(LinearGradient(colors: [color.opacity(0.28), color.opacity(0.015)],
                                                    startPoint: .top, endPoint: .bottom))
                    .accessibilityHidden(true)
                LineMark(x: .value("Time", b.start, unit: range.unit), y: .value(valueLabel, b.value))
                    .interpolationMethod(.monotone)
                    .lineStyle(StrokeStyle(lineWidth: 2.75, lineCap: .round, lineJoin: .round))
                    .foregroundStyle(color.opacity(0.9))
                    .accessibilityLabel(bucketLabel(b.start))
                    .accessibilityValue(metric.format(b.value))
            }
            if let b = summary.buckets.first(where: { $0.start == hovered }) {
                RuleMark(x: .value("Time", b.start, unit: range.unit))
                    .lineStyle(StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
                    .foregroundStyle(t.subtext.opacity(0.4))
                    .accessibilityHidden(true)
                PointMark(x: .value("Time", b.start, unit: range.unit), y: .value(valueLabel, b.value))
                    .symbolSize(32).foregroundStyle(color)
                    .accessibilityHidden(true)
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { v in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(t.border.opacity(0.6))
                AxisValueLabel {
                    if let n = v.as(Double.self) {
                        Text(metric == .cost ? "$" + compact(n) : compact(n))
                            .font(.system(size: 9, weight: .medium)).foregroundStyle(t.muted)
                            .fixedSize()
                    }
                }
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
                        let plot = g[proxy.plotAreaFrame]
                        guard case .active(let p) = phase,
                              plot.contains(p), let d: Date = proxy.value(atX: p.x - plot.origin.x)
                        else { hovered = nil; return }
                        hovered = (account ? usageUTCCalendar : Calendar.current).dateInterval(of: range.unit, for: d)?.start
                    }
            }
        }
        .frame(height: 108)
        .environment(\.timeZone, account ? usageUTCCalendar.timeZone : .current)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: metric)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: range)
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
    @State private var hovered = false

    var body: some View {
        let c = metric.color(t)
        Button(action: action) {
            Group {
                if metric == .cost {
                    HStack(alignment: .top, spacing: 8) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("API equivalent").font(.system(size: 11, weight: .medium))
                                .foregroundStyle(selected ? c : t.subtext)
                            if let caption { Text(caption).font(.system(size: 9)).foregroundStyle(t.muted) }
                        }
                        Spacer(minLength: 0)
                        valueText
                    }
                } else {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 5) {
                            Text(metric.label).font(.system(size: 10)).foregroundStyle(selected ? c : t.muted)
                            if selected { Circle().fill(c).frame(width: 4, height: 4) }
                        }
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            valueText
                            if let caption { Text(caption).font(.system(size: 9)).foregroundStyle(t.muted) }
                        }
                    }
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(selected ? c.opacity(0.065) : t.text.opacity(hovered ? 0.035 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hovered = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var valueText: some View {
        Text(metric.format(value))
            .font(.system(size: 16, weight: .semibold).monospacedDigit())
            .foregroundStyle(t.text)
            .tracking(-0.3)
            .lineLimit(1).minimumScaleFactor(0.7)
            .contentTransition(.numericText())
    }
}

struct ModelList: View {
    let rows: [(name: String, value: Double)]
    let metric: TokenMetric
    @Environment(\.theme) private var t

    var body: some View {
        let top = rows.prefix(4)
        let total = max(0.000_001, rows.reduce(0) { $0 + $1.value })
        VStack(alignment: .leading, spacing: 14) {
            Text("By model").font(.system(size: 11, weight: .medium)).foregroundStyle(t.subtext)
            ForEach(Array(top), id: \.name) { r in
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Text(r.name).font(.system(size: 11)).lineLimit(1)
                        Spacer()
                        Text("\(metric.format(r.value)) · \(Int((r.value / total * 100).rounded()))%")
                            .font(.system(size: 10).monospacedDigit())
                            .foregroundStyle(t.muted)
                            .fixedSize()
                    }
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(t.track)
                            Capsule().fill(LinearGradient(colors: [metric.color(t).opacity(0.35), metric.color(t).opacity(0.75)],
                                                          startPoint: .leading, endPoint: .trailing))
                                .frame(width: r.value > 0 ? max(3, g.size.width * r.value / total) : 0)
                        }
                    }
                    .frame(height: 4)
                }
                .help("\(r.name): \(metric.format(r.value))")
            }
        }
    }
}

/// The ChatGPT plan's recent windows, as Codex's /usage shows them. Click a window to see which
/// models used it. Covers every surface (Codex CLI, IDE, cloud, OpenCode), unlike the token counts.
struct PlanHistoryCard: View {
    let history: PlanHistory
    @State private var selected: String?
    @State private var expanded = false
    @Environment(\.theme) private var t

    var body: some View {
        let now = Date()
        let chosen = history.periods.first { $0.id == selected } ?? history.periods.first
        Card {
            VStack(alignment: .leading, spacing: 14) {
                Button { expanded.toggle() } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Recent plan usage").font(.system(size: 12, weight: .medium)).foregroundStyle(t.subtext)
                            Text(history.asOf.map { "All devices · updated \(day($0))" } ?? "Across all devices")
                                .font(.system(size: 10)).foregroundStyle(t.muted)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .medium)).foregroundStyle(t.muted)
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityValue(expanded ? "Expanded" : "Collapsed")
                if expanded {
                    ForEach(history.periods.prefix(5)) { p in
                        Button { selected = p.id } label: {
                            row(p, current: p.end > now, chosen: p.id == chosen?.id)
                        }
                        .buttonStyle(.plain)
                    }
                    if let chosen, !chosen.byModel.isEmpty {
                        Rectangle().fill(t.border.opacity(0.6)).frame(height: 0.5)
                        Text("By model, \(range(chosen))").font(.system(size: 10)).foregroundStyle(t.muted)
                        ForEach(chosen.byModel.prefix(4), id: \.name) { m in
                            HStack {
                                Text(m.name).font(.system(size: 11))
                                Spacer()
                                Text(pct(m.value)).font(.system(size: 11).monospacedDigit())
                                    .foregroundStyle(t.muted)
                            }
                        }
                    }
                }
            }
        }
        .help("Share of each window's limit used, across Codex CLI, IDE, cloud and OpenCode. Updated daily by OpenAI.")
    }

    private func row(_ p: PlanPeriod, current: Bool, chosen: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(range(p)).font(.system(size: 11, weight: chosen ? .medium : .regular))
                if current {
                    Text("Now").font(.system(size: 9)).foregroundStyle(t.accent)
                }
                Spacer()
                Text(pct(p.used)).font(.system(size: 11, weight: .medium).monospacedDigit())
            }
            LimitMeter(pct: p.used, marker: nil)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(chosen ? t.text.opacity(0.045) : .clear))
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
            VStack(alignment: .leading, spacing: 14) {
                Text("All-time activity").font(.system(size: 11, weight: .medium)).foregroundStyle(t.subtext)
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 14) {
                    stat("Lifetime", compact(activity.lifetime), "tokens")
                    stat("Peak day", compact(activity.peakDay), "tokens")
                    stat("Streak", "\(activity.currentStreak)d", "best \(activity.longestStreak)d")
                    if let c = activity.chats { stat("Chats", compact(Double(c)), "all time") }
                }
            }
        }
        .help(activity.effort.map { "Mostly \($0.name) reasoning (\(Int($0.share.rounded()))% of turns)" } ?? "")
    }

    private func stat(_ label: String, _ value: String, _ caption: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 10)).foregroundStyle(t.muted)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value).font(.system(size: 15, weight: .semibold).monospacedDigit())
                Text(caption).font(.system(size: 9)).foregroundStyle(t.muted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
