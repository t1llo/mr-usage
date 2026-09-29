// The Tokens tab: tokens per hour or day as a bar chart, totals as tiles, split by model.
import Charts
import SwiftUI

extension TokenMetric {
    func color(_ t: Theme) -> Color {
        switch self {
        case .cost: return t.green
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

struct TokensView: View {
    @ObservedObject var tokens: TokenStore
    let provider: Provider
    @AppStorage("tokenRange") private var range: TokenRange = .week
    @AppStorage("tokenMetric") private var metric: TokenMetric = .cost
    @State private var hovered: Date?
    @Environment(\.theme) private var t

    var body: some View {
        let s = summarize(tokens.records, provider: provider, range: range, metric: metric)
        VStack(alignment: .leading, spacing: 10) {
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline) {
                        readout(s)
                        Spacer()
                        Segmented(options: TokenRange.allCases, selection: $range) { $0.rawValue }
                    }
                    if tokens.loaded { chart(s) } else {
                        ProgressView().controlSize(.small).frame(maxWidth: .infinity, minHeight: 120)
                    }
                }
            }
            MetricTile(metric: .cost, value: s.totals[.cost] ?? 0, selected: metric == .cost,
                       caption: "if billed at API prices", help: metric.help(provider)) { metric = .cost }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                ForEach(TokenMetric.tokenKinds) { m in
                    MetricTile(metric: m, value: s.totals[m] ?? 0, selected: m == metric, help: m.help(provider)) { metric = m }
                }
            }
            if !s.byModel.isEmpty { Card { ModelList(rows: s.byModel, metric: metric) } }
            if metric == .cost, !s.unpriced.isEmpty {
                Text("No API price for \(s.unpriced.sorted().joined(separator: ", ")), left out of the cost")
                    .font(.caption2).foregroundStyle(t.warn)
                    .frame(maxWidth: .infinity)
            }
            Text(footnote)
                .font(.caption2).foregroundStyle(t.muted)
                .frame(maxWidth: .infinity)
        }
    }

    /// Which tools the numbers come from, or where they would come from.
    private var footnote: String {
        let tools: [Source] = provider == .claude ? [.claudeCode, .opencode] : [.codex, .opencode]
        let found = tools.filter { tokens.sources.contains($0) }
        let names = (found.isEmpty ? tools : found).map(\.rawValue).joined(separator: " and ")
        return found.isEmpty ? "No \(names) logs on this Mac yet" : "From \(names) sessions on this Mac"
    }

    /// Hovered bucket's value, or the range total for the selected metric.
    private func readout(_ s: TokenSummary) -> some View {
        let b = hovered.flatMap { h in s.buckets.first { $0.start == h } }
        return VStack(alignment: .leading, spacing: 1) {
            Text(metric.format(b?.value ?? s.totals[metric] ?? 0))
                .font(.system(size: 20, weight: .bold, design: .rounded).monospacedDigit())
                .contentTransition(.numericText())
            Text("\(metric == .cost ? "API cost" : metric.rawValue.lowercased()) · \(b.map { bucketLabel($0.start) } ?? "last \(range.rawValue)")")
                .font(.caption).foregroundStyle(t.muted)
        }
    }

    private func bucketLabel(_ d: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US")
        f.dateFormat = range == .day ? "EEE ha" : "EEE MMM d"
        return f.string(from: d).replacingOccurrences(of: "AM", with: "am").replacingOccurrences(of: "PM", with: "pm")
    }

    private func chart(_ s: TokenSummary) -> some View {
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
                        hovered = Calendar.current.dateInterval(of: range.unit, for: d)?.start
                    }
            }
        }
        .frame(height: 120)
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
