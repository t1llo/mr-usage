// The panel that drops down from the menu bar: session as a ring, other limits as bars.
import ServiceManagement
import SwiftUI

/// Accent while there is room, orange from 75%, red from 90%.
func levelColor(_ pct: Double) -> Color { pct >= 90 ? .red : pct >= 75 ? .orange : .accentColor }

struct UsagePanel: View {
    @ObservedObject var store: Store
    @State private var openAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            // Re-render every 30 s so the "resets in" countdowns stay current while open.
            TimelineView(.periodic(from: .now, by: 30)) { ctx in
                content(now: ctx.date)
            }
            Divider()
            footer
        }
        .padding(16)
        .frame(width: 300)
        .onAppear { store.tick() }
    }

    private var header: some View {
        HStack {
            Text("Claude usage").font(.headline)
            Spacer()
            Button { store.tick() } label: {
                Image(systemName: "arrow.clockwise")
                    .rotationEffect(.degrees(store.inFlight ? 360 : 0))
                    .animation(store.inFlight ? .linear(duration: 1).repeatForever(autoreverses: false) : .default,
                               value: store.inFlight)
            }
            .buttonStyle(.borderless)
            .keyboardShortcut("r")
            .help("Refresh")
        }
    }

    @ViewBuilder private func content(now: Date) -> some View {
        if let u = store.usage {
            VStack(alignment: .leading, spacing: 14) {
                if let session = u.limits.first { SessionCard(limit: session, now: now) }
                ForEach(u.limits.dropFirst()) { l in
                    BarRow(label: l.label, pct: l.pct, value: "\(Int(l.pct))%",
                           caption: "Resets \(countdown(to: l.resetsAt, now: now)) · \(resetClock(l.resetsAt))")
                }
                if let c = u.credits {
                    let pct = (c.limitCents ?? 0) > 0 ? c.usedCents / c.limitCents! * 100 : 0
                    BarRow(label: "Extra usage", pct: pct,
                           value: "\(money(c.usedCents)) / \(c.limitCents.map(money) ?? "no limit")",
                           caption: "Resets \(firstOfNextMonth())")
                }
            }
        } else {
            HStack(spacing: 8) {
                if store.inFlight { ProgressView().controlSize(.small) }
                Text(store.status).font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 60)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if store.usage != nil {
                Text(store.status)
                    .font(.caption)
                    .foregroundStyle(store.lastError == nil ? .secondary : Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Toggle("Open at login", isOn: Binding(get: { openAtLogin }, set: setOpenAtLogin))
                    .toggleStyle(.checkbox)
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
            }
            .controlSize(.small)
        }
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

/// The five-hour session window, shown large because it is the one that runs out first.
struct SessionCard: View {
    let limit: Limit
    let now: Date

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().stroke(.quaternary, lineWidth: 7)
                Circle()
                    .trim(from: 0, to: min(1, limit.pct / 100))
                    .stroke(levelColor(limit.pct), style: StrokeStyle(lineWidth: 7, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text("\(Int(limit.pct))%")
                    .font(.system(size: 15, weight: .semibold).monospacedDigit())
            }
            .frame(width: 62, height: 62)
            VStack(alignment: .leading, spacing: 3) {
                Text(limit.label).font(.system(size: 13, weight: .medium))
                if limit.resetsAt != nil {
                    Text("Resets \(countdown(to: limit.resetsAt, now: now))")
                        .font(.callout)
                    Text("at \(resetClock(limit.resetsAt))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.5)))
    }
}

struct BarRow: View {
    let label: String
    let pct: Double
    let value: String
    let caption: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(label).font(.system(size: 13, weight: .medium))
                Spacer()
                Text(value).font(.system(size: 13).monospacedDigit()).foregroundStyle(.secondary)
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(levelColor(pct))
                        .frame(width: pct > 0 ? max(6, g.size.width * min(1, pct / 100)) : 0)
                }
            }
            .frame(height: 6)
            Text(caption).font(.caption).foregroundStyle(.secondary)
        }
    }
}
