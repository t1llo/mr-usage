// The panel that drops down from the menu bar: session as a ring hero, other limits as bars.
// Every limit also shows where usage *would* be at an even burn rate, so the panel answers
// "am I spending faster than the clock?" and not just "how much is left".
import ServiceManagement
import SwiftUI

/// Accent while there is room, orange from 75%, red from 90%.
func levelColor(_ pct: Double) -> Color { pct >= 90 ? .red : pct >= 75 ? .orange : .accentColor }

// MARK: - Pace

/// How usage compares with the clock. "Ahead" means usage is running ahead of elapsed time.
enum Pace {
    case ahead, on, under, exhausted

    var label: String {
        switch self {
        case .ahead: return "Ahead of pace"
        case .on: return "On pace"
        case .under: return "Under pace"
        case .exhausted: return "Limit reached"
        }
    }
    var icon: String {
        switch self {
        case .ahead: return "hare.fill"
        case .on: return "checkmark.circle.fill"
        case .under: return "tortoise.fill"
        case .exhausted: return "exclamationmark.circle.fill"
        }
    }
    var color: Color {
        switch self {
        case .ahead: return .orange
        case .on: return .secondary
        case .under: return .green
        case .exhausted: return .red
        }
    }
}

struct PaceInfo {
    /// Fraction of the window that has passed, 0...1.
    let elapsed: Double
    let pace: Pace
    /// Tooltip text that explains the verdict in numbers.
    let detail: String
}

extension Limit {
    /// Session windows are five hours, everything else is weekly.
    var windowLength: TimeInterval { id == "five_hour" ? 5 * 3600 : 7 * 86_400 }

    /// Nil when there is no active window (the API sends no reset date until the first message).
    func pace(now: Date) -> PaceInfo? {
        guard let reset = resetsAt else { return nil }
        let elapsed = min(1, max(0, 1 - reset.timeIntervalSince(now) / windowLength))
        let used = pct / 100
        // A ten-point band counts as "on pace" so the label does not flap around the line.
        let pace: Pace = pct >= 100 ? .exhausted
            : used > elapsed + 0.10 ? .ahead
            : used < elapsed - 0.10 ? .under
            : .on
        let detail = "\(Int(pct))% used with \(Int(elapsed * 100))% of the window elapsed"
        return PaceInfo(elapsed: elapsed, pace: pace, detail: detail)
    }
}

// MARK: - Panel

struct UsagePanel: View {
    @ObservedObject var store: Store
    @State private var openAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            // Re-render every 30 s so countdowns and pace markers stay current while open.
            TimelineView(.periodic(from: .now, by: 30)) { ctx in
                content(now: ctx.date)
            }
            if store.usage != nil, let e = store.lastError, !store.inFlight {
                ErrorBanner(text: "Couldn't refresh: \(e). Retrying at \(clock(store.nextFetchAt)).")
            }
            footer
        }
        .padding(14)
        .frame(width: 316)
        .onAppear { store.tick() }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Claude usage").font(.system(size: 15, weight: .semibold))
            Spacer()
            Text(subtitle).font(.caption).foregroundStyle(.tertiary).monospacedDigit()
            Button { store.tick() } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(store.inFlight ? 360 : 0))
                    .animation(store.inFlight ? .linear(duration: 1).repeatForever(autoreverses: false) : .default,
                               value: store.inFlight)
            }
            .buttonStyle(.borderless)
            .keyboardShortcut("r")
            .help("Refresh")
        }
        .padding(.horizontal, 2)
    }

    private var subtitle: String {
        if store.inFlight { return "Refreshing…" }
        if let at = store.lastGoodAt { return "Updated \(clock(at))" }
        return ""
    }

    @ViewBuilder private func content(now: Date) -> some View {
        if let u = store.usage {
            VStack(alignment: .leading, spacing: 10) {
                if let session = u.limits.first { SessionCard(limit: session, now: now) }
                let weekly = Array(u.limits.dropFirst())
                if !weekly.isEmpty {
                    Card {
                        VStack(alignment: .leading, spacing: 14) {
                            ForEach(weekly) { l in
                                BarRow(icon: icon(for: l.id), label: l.label, pct: l.pct,
                                       value: "\(Int(l.pct))%",
                                       caption: "Resets \(countdown(to: l.resetsAt, now: now)) · \(resetClock(l.resetsAt))",
                                       pace: l.pace(now: now))
                            }
                        }
                    }
                }
                if let c = u.credits {
                    let pct = (c.limitCents ?? 0) > 0 ? c.usedCents / c.limitCents! * 100 : 0
                    Card {
                        BarRow(icon: "creditcard.fill", label: "Extra usage", pct: pct,
                               value: "\(money(c.usedCents)) / \(c.limitCents.map(money) ?? "no limit")",
                               caption: "Resets \(firstOfNextMonth())", pace: nil)
                    }
                }
            }
        } else {
            EmptyState(loading: store.inFlight, text: store.status)
        }
    }

    private func icon(for id: String) -> String {
        switch id {
        case "seven_day_sonnet": return "s.circle.fill"
        case "seven_day_opus": return "o.circle.fill"
        default: return "calendar"
        }
    }

    private var footer: some View {
        HStack {
            Toggle("Open at login", isOn: Binding(get: { openAtLogin }, set: setOpenAtLogin))
                .toggleStyle(.checkbox)
            Spacer()
            Button("Quit") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
        .controlSize(.small)
        .padding(.horizontal, 2)
        .padding(.top, 2)
    }

    private func setOpenAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            store.lastError = "login item: \(error.localizedDescription)"
        }
        openAtLogin = SMAppService.mainApp.status == .enabled
    }
}

// MARK: - Building blocks

/// Soft inset card. Uses the label color at low opacity so it lifts in dark mode and
/// recedes in light mode without any per-appearance branching.
struct Card<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.primary.opacity(0.045)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.primary.opacity(0.06)))
    }
}

struct PacePill: View {
    let info: PaceInfo

    var body: some View {
        Label(info.pace.label, systemImage: info.pace.icon)
            .font(.caption.weight(.semibold))
            .foregroundStyle(info.pace.color)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(info.pace.color.opacity(0.12)))
            .help(info.detail)
    }
}

struct ErrorBanner: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .font(.caption)
        .foregroundStyle(.orange)
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.orange.opacity(0.1)))
    }
}

struct EmptyState: View {
    let loading: Bool
    let text: String

    var body: some View {
        VStack(spacing: 8) {
            if loading {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.title3)
                    .foregroundStyle(.orange)
            }
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, minHeight: 110)
    }
}

// MARK: - Session hero

/// The five-hour session window, shown large because it is the one that runs out first.
struct SessionCard: View {
    let limit: Limit
    let now: Date

    var body: some View {
        let info = limit.pace(now: now)
        Card {
            HStack(spacing: 16) {
                RingGauge(pct: limit.pct, marker: info?.elapsed)
                    .frame(width: 84, height: 84)
                VStack(alignment: .leading, spacing: 4) {
                    Label(limit.label, systemImage: "bolt.fill")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    if limit.resetsAt != nil {
                        Text(remaining(to: limit.resetsAt, now: now))
                            .font(.system(size: 20, weight: .semibold, design: .rounded).monospacedDigit())
                            .contentTransition(.numericText())
                        Text("until reset at \(resetClock(limit.resetsAt))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("No active session")
                            .font(.system(size: 15, weight: .medium, design: .rounded))
                        Text("Starts with your next message")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let info { PacePill(info: info).padding(.top, 4) }
                }
                Spacer(minLength: 0)
            }
        }
    }
}

/// Gradient arc on a faint track. `marker` (0...1) drops a dot where the arc would end
/// at an even pace, so the gap between dot and arc tip is the story at a glance.
struct RingGauge: View {
    let pct: Double
    let marker: Double?

    private let lineWidth: CGFloat = 9

    var body: some View {
        let color = levelColor(pct)
        let fill = min(1, pct / 100)
        ZStack {
            Circle()
                .stroke(.primary.opacity(0.08), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: fill)
                .stroke(
                    AngularGradient(colors: [color.opacity(0.55), color], center: .center,
                                    startAngle: .degrees(0), endAngle: .degrees(360 * max(fill, 0.02))),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .shadow(color: color.opacity(0.35), radius: 5)
                .animation(.easeOut(duration: 0.7), value: pct)
            if let marker {
                GeometryReader { g in
                    Circle()
                        .fill(.primary.opacity(0.45))
                        .frame(width: 5, height: 5)
                        .position(x: g.size.width / 2, y: 0)
                        .rotationEffect(.degrees(360 * marker))
                }
            }
            Text("\(Int(pct))%")
                .font(.system(size: 20, weight: .bold, design: .rounded).monospacedDigit())
                .contentTransition(.numericText())
                .animation(.easeOut(duration: 0.7), value: pct)
        }
        .padding(lineWidth / 2)
    }
}

// MARK: - Bars

struct BarRow: View {
    let icon: String
    let label: String
    let pct: Double
    let value: String
    let caption: String
    let pace: PaceInfo?

    var body: some View {
        let color = levelColor(pct)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 14)
                Text(label).font(.system(size: 13, weight: .medium))
                Spacer()
                Text(value)
                    .font(.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit())
                    .contentTransition(.numericText())
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(.primary.opacity(0.08))
                    Capsule()
                        .fill(LinearGradient(colors: [color.opacity(0.7), color], startPoint: .leading, endPoint: .trailing))
                        .frame(width: pct > 0 ? max(8, g.size.width * min(1, pct / 100)) : 0)
                        .animation(.easeOut(duration: 0.7), value: pct)
                    if let pace {
                        // Even-pace marker: usage to the right of it is running ahead of the clock.
                        RoundedRectangle(cornerRadius: 1)
                            .fill(.primary.opacity(0.45))
                            .frame(width: 2, height: 12)
                            .position(x: max(1, min(g.size.width - 1, g.size.width * pace.elapsed)), y: g.size.height / 2)
                            .help(pace.detail)
                    }
                }
            }
            .frame(height: 7)
            HStack {
                Text(caption).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let pace {
                    Label(pace.pace.label, systemImage: pace.pace.icon)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(pace.pace.color)
                        .help(pace.detail)
                }
            }
        }
    }
}
