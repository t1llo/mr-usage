// The panel that drops down from the menu bar. A provider picker (Claude or OpenAI) in the header,
// then two tabs: Limits (session as a ring hero, other limits as bars, each with an even-pace
// marker) and Tokens (see TokensView.swift).
import AppKit
import ServiceManagement
import SwiftUI

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
    func color(_ t: Theme) -> Color {
        switch self {
        case .ahead: return t.warn
        case .on: return t.subtext
        case .under: return t.green
        case .exhausted: return t.red
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
    /// Nil when there is no active window (the API sends no reset date until the first message).
    func pace(now: Date) -> PaceInfo? {
        guard let reset = resetsAt, let window, window > 0 else { return nil }
        let elapsed = min(1, max(0, 1 - reset.timeIntervalSince(now) / window))
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

enum PanelTab: String, CaseIterable { case limits = "Limits", tokens = "Tokens" }

extension Provider {
    var icon: String { self == .claude ? "sparkle" : "hexagon.fill" }
    var detail: String { self == .claude ? "Claude Code, OpenCode" : "Codex CLI, OpenCode" }
}

/// "plus" -> "Plus", "prolite" -> "Pro Lite", "self_serve_business_usage_based" -> "Business".
func planName(_ plan: String) -> String {
    switch plan {
    case "prolite": return "Pro Lite"
    case "promax": return "Pro Max"
    case "edu_plus": return "Edu Plus"
    case "edu_pro": return "Edu Pro"
    case let p where p.contains("business"): return "Business"
    case let p where p.hasPrefix("ent"): return "Enterprise"
    default: return plan.prefix(1).uppercased() + plan.dropFirst()
    }
}

/// "3:40pm" today, otherwise "Mon 3:40pm".
func dayClock(_ d: Date) -> String {
    Calendar.current.isDateInToday(d) ? clock(d) : resetClock(d)
}

struct UsagePanel: View {
    @ObservedObject var store: Store
    @ObservedObject var tokens: TokenStore
    @ObservedObject var leaderboard: LeaderboardStore
    @AppStorage("theme") private var themeID = Theme.tokyoNight.id
    @AppStorage("tab") private var tab: PanelTab = .limits
    @AppStorage("provider") private var provider: Provider = .claude
    @State private var picking = false
    @State private var choosingTheme = false
    @State private var showingSettings = false
    @State private var openAtLogin = SMAppService.mainApp.status == .enabled

    private var t: Theme { Theme.named(themeID) }
    private var panelHeight: CGFloat { min(680, (NSScreen.main?.visibleFrame.height ?? 700) - 20) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Segmented(options: PanelTab.allCases, selection: Binding(
                get: { tab },
                set: { tab = $0; showingSettings = false }
            ), fill: true, showsSelection: !showingSettings) { $0.rawValue }
            .frame(height: 28)
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 12) {
                    if showingSettings {
                        LeaderboardSettingsView(leaderboard: leaderboard)
                    } else {
                        tabContent
                        if provider == .claude, store.usage != nil, let e = store.lastError, !store.inFlight {
                            ErrorBanner(text: "Couldn't refresh: \(e). Retrying at \(clock(store.nextFetchAt)).")
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // Each page starts at the top rather than inheriting another page's scroll offset.
            .id(showingSettings ? "settings" : "\(provider.rawValue)/\(tab.rawValue)")
            footer
        }
        .padding(14)
        // MenuBarExtra repositions when its intrinsic size changes. Keep its viewport stable
        // across tabs, providers and refreshes; longer pages scroll below the fixed header.
        .frame(width: 320, height: panelHeight, alignment: .top)
        .background(background)
        .foregroundStyle(t.text)
        .environment(\.theme, t)
        .preferredColorScheme(t.isDark ? .dark : .light)
        .onAppear { store.tick(); tokens.refresh() }
        .onChange(of: tab) { if $0 == .tokens { tokens.refresh() } }
        .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { _ in
            if tab == .tokens && !showingSettings { tokens.refresh() }
        }
    }

    @ViewBuilder private var tabContent: some View {
        switch tab {
        case .limits:
            // Re-render every 30 s so countdowns and pace markers stay current while open.
            TimelineView(.periodic(from: .now, by: 30)) { ctx in
                switch provider {
                case .claude: claudeLimits(now: ctx.date)
                case .openai: openAILimits(now: ctx.date)
                }
            }
        case .tokens:
            TokensView(tokens: tokens, provider: provider)
        }
    }

    private var background: some View { t.base.ignoresSafeArea() }

    private var header: some View {
        HStack(spacing: 8) {
            if showingSettings {
                Text("Settings").font(.system(size: 15, weight: .semibold, design: .rounded))
            } else {
                providerPicker
            }
            Spacer(minLength: 0)
            HStack(spacing: 4) {
                Button { choosingTheme.toggle() } label: {
                    Image(systemName: "paintpalette.fill")
                }
                .buttonStyle(PanelToolbarButtonStyle(selected: choosingTheme))
                .help("Choose color theme")
                .accessibilityLabel("Color theme")
                .accessibilityValue(t.name)
                .popover(isPresented: $choosingTheme, arrowEdge: .bottom) {
                    ThemePicker(selection: $themeID)
                        .padding(8)
                        .frame(width: 250)
                        .foregroundStyle(t.text)
                        .background(t.card)
                        .environment(\.theme, t)
                        .preferredColorScheme(t.isDark ? .dark : .light)
                }
                Button { store.tick(); tokens.refresh() } label: {
                    Image(systemName: "arrow.clockwise")
                        .rotationEffect(.degrees(store.inFlight ? 360 : 0))
                        .animation(store.inFlight ? .linear(duration: 1).repeatForever(autoreverses: false) : .default,
                                   value: store.inFlight)
                }
                .buttonStyle(PanelToolbarButtonStyle())
                .keyboardShortcut("r")
                .help("Refresh")
                .accessibilityLabel("Refresh usage")
                Button { showingSettings.toggle() } label: {
                    Image(systemName: showingSettings ? "xmark" : "gearshape.fill")
                }
                .buttonStyle(PanelToolbarButtonStyle(selected: showingSettings))
                .keyboardShortcut(showingSettings ? .escape : ",", modifiers: showingSettings ? [] : .command)
                .help(showingSettings ? "Back to usage (Esc)" : "Settings")
                .accessibilityLabel(showingSettings ? "Close settings" : "Settings")
            }
        }
        .padding(.horizontal, 2)
    }

    /// Provider name with a chevron; opens a themed list rather than a system menu, so it
    /// matches the rest of the panel.
    private var providerPicker: some View {
        Button { picking.toggle() } label: {
            HStack(spacing: 6) {
                Image(systemName: provider.icon)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(t.accent)
                Text("\(provider.rawValue) usage").font(.system(size: 15, weight: .semibold, design: .rounded))
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(t.muted)
                    .rotationEffect(.degrees(picking ? 180 : 0))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Switch provider")
        .popover(isPresented: $picking, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Provider.allCases) { p in
                    Button { choose(p) } label: {
                        HStack(spacing: 8) {
                            Image(systemName: p.icon).foregroundStyle(t.accent).frame(width: 16)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(p.rawValue).font(.system(size: 13, weight: .semibold))
                                Text(p.detail).font(.caption).foregroundStyle(t.muted)
                            }
                            Spacer(minLength: 12)
                            if p == provider { Image(systemName: "checkmark").foregroundStyle(t.accent) }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(p == provider ? t.accent.opacity(0.12) : .clear))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(6)
            .frame(width: 230)
            .foregroundStyle(t.text)
            .background(t.card)
            .environment(\.theme, t)
            .preferredColorScheme(t.isDark ? .dark : .light)
        }
    }

    /// Close the list before replacing its source view, keeping the popover dismissal and
    /// provider content update out of the same animated transaction.
    private func choose(_ p: Provider) {
        picking = false
        guard p != provider else { return }
        DispatchQueue.main.async {
            var tx = Transaction()
            tx.disablesAnimations = true
            withTransaction(tx) { provider = p }
        }
    }

    @ViewBuilder private func claudeLimits(now: Date) -> some View {
        if let u = store.usage {
            limitCards(u, now: now)
        } else {
            EmptyState(loading: store.inFlight, text: store.status)
        }
    }

    @ViewBuilder private func openAILimits(now: Date) -> some View {
        if let cx = tokens.codexLimits {
            VStack(alignment: .leading, spacing: 10) {
                limitCards(cx.current(now: now), now: now)
                if let credits = tokens.codexCredits { OpenAICreditsCard(credits: credits) }
                Text([cx.plan.map { "ChatGPT " + planName($0) }, cx.live ? "live" : "from Codex logs, \(dayClock(cx.asOf))"]
                        .compactMap { $0 }.joined(separator: " · "))
                    .font(.caption2).foregroundStyle(t.muted)
                    .frame(maxWidth: .infinity)
                    .help(cx.live ? "Fetched from ChatGPT with Codex's login"
                          : "Codex logs your plan's limits with every request, so use elsewhere (OpenCode, ChatGPT) shows up after your next Codex request.")
                if !cx.live, let e = tokens.liveError { ErrorBanner(text: "Live limits unavailable: \(e).") }
                if let h = tokens.planHistory { PlanHistoryCard(history: h) }
            }
        } else {
            EmptyState(loading: !tokens.loaded, text: !tokens.loaded ? "Reading Codex logs…"
                : tokens.sources.contains(.codex)
                    ? "Codex hasn't logged any limits yet. They show up after your next Codex request."
                    : tokens.sources.contains(.opencode)
                        ? "OpenCode doesn't record ChatGPT limits. Run Codex CLI once to see them; token usage is in the Tokens tab."
                        : "No Codex CLI logs in ~/.codex. Sign in to Codex with your ChatGPT account and run it once.")
        }
    }

    private func limitCards(_ u: Usage, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let session = u.limits.first { SessionCard(limit: session, now: now) }
            let weekly = Array(u.limits.dropFirst())
            if !weekly.isEmpty {
                Card {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(weekly) { l in
                            BarRow(icon: icon(for: l.id), label: l.label, pct: l.pct,
                                   value: "\(Int(l.pct))%",
                                   caption: l.resetsAt == nil ? "Not started"
                                       : "Resets \(countdown(to: l.resetsAt, now: now)) · \(resetClock(l.resetsAt))",
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
            Button { setOpenAtLogin(!openAtLogin) } label: {
                Label("Open at login", systemImage: openAtLogin ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(openAtLogin ? t.accent : t.muted)
            }
            Spacer()
            SoftwareUpdateMenu().foregroundStyle(t.muted)
            Button("Quit") { NSApp.terminate(nil) }
                .foregroundStyle(t.muted)
                .keyboardShortcut("q")
        }
        .buttonStyle(.plain)
        .font(.system(size: 11, weight: .medium))
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

struct Card<Content: View>: View {
    @ViewBuilder let content: Content
    @Environment(\.theme) private var t

    var body: some View {
        content
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(t.card))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(t.border.opacity(0.6), lineWidth: 0.75))
    }
}

struct PacePill: View {
    let info: PaceInfo
    @Environment(\.theme) private var t

    var body: some View {
        let c = info.pace.color(t)
        Label(info.pace.label, systemImage: info.pace.icon)
            .font(.caption.weight(.semibold))
            .foregroundStyle(c)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(c.opacity(0.14)))
            .help(info.detail)
    }
}

struct ErrorBanner: View {
    let text: String
    @Environment(\.theme) private var t

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .font(.caption)
        .foregroundStyle(t.warn)
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(t.warn.opacity(0.12)))
    }
}

struct EmptyState: View {
    let loading: Bool
    let text: String
    @Environment(\.theme) private var t

    var body: some View {
        VStack(spacing: 8) {
            if loading {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.title3)
                    .foregroundStyle(t.warn)
            }
            Text(text)
                .font(.callout)
                .foregroundStyle(t.subtext)
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
    @Environment(\.theme) private var t

    var body: some View {
        let info = limit.pace(now: now)
        Card {
            HStack(spacing: 16) {
                RingGauge(pct: limit.pct, marker: info?.elapsed)
                    .frame(width: 84, height: 84)
                VStack(alignment: .leading, spacing: 4) {
                    Label(limit.label, systemImage: "bolt.fill")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(t.subtext)
                    if limit.resetsAt != nil {
                        Text(remaining(to: limit.resetsAt, now: now))
                            .font(.system(size: 20, weight: .semibold, design: .rounded).monospacedDigit())
                            .contentTransition(.numericText())
                        Text("until reset at \(resetClock(limit.resetsAt))")
                            .font(.caption)
                            .foregroundStyle(t.muted)
                    } else {
                        Text("No active session")
                            .font(.system(size: 15, weight: .medium, design: .rounded))
                        Text("Starts with your next message")
                            .font(.caption)
                            .foregroundStyle(t.muted)
                    }
                    if let info { PacePill(info: info).padding(.top, 4) }
                }
                Spacer(minLength: 0)
            }
        }
    }
}

/// Arc on a faint track. `marker` (0...1) drops a dot where the arc would end
/// at an even pace, so the gap between dot and arc tip is the story at a glance.
struct RingGauge: View {
    let pct: Double
    let marker: Double?
    @Environment(\.theme) private var t

    private let lineWidth: CGFloat = 9

    var body: some View {
        let fill = min(1, pct / 100)
        ZStack {
            Circle()
                .stroke(t.track, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: fill)
                .stroke(t.level(pct), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.7), value: pct)
            if let marker {
                GeometryReader { g in
                    Circle()
                        .fill(t.text.opacity(0.7))
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

// MARK: - OpenAI credits

struct OpenAICreditsCard: View {
    let credits: CodexCredits
    @Environment(\.theme) private var t

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 7) {
                Label("Credit balance", systemImage: "creditcard.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(t.subtext)
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(credits.displayBalance)
                        .font(.system(size: 23, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(t.accent)
                        .contentTransition(.numericText())
                    if !credits.unlimited, credits.balance != nil {
                        Text("credits").font(.caption).foregroundStyle(t.subtext)
                    }
                }
                Text("Used after your plan's included usage.")
                    .font(.caption).foregroundStyle(t.muted)
                Text("\(credits.live ? "Updated" : "From Codex logs ·") \(dayClock(credits.asOf))")
                    .font(.caption2).foregroundStyle(t.muted)
            }
        }
        .help("OpenAI usage credits, including grants reflected in your balance. Separate from estimated API costs.")
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
    @Environment(\.theme) private var t

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(t.level(pct))
                    .frame(width: 14)
                Text(label).font(.system(size: 13, weight: .medium))
                Spacer()
                Text(value)
                    .font(.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit())
                    .contentTransition(.numericText())
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(t.track)
                    Capsule()
                        .fill(t.level(pct))
                        .frame(width: pct > 0 ? max(8, g.size.width * min(1, pct / 100)) : 0)
                        .animation(.easeOut(duration: 0.7), value: pct)
                    if let pace {
                        // Even-pace marker: usage to the right of it is running ahead of the clock.
                        RoundedRectangle(cornerRadius: 1)
                            .fill(t.text.opacity(0.7))
                            .frame(width: 2, height: 12)
                            .position(x: max(1, min(g.size.width - 1, g.size.width * pace.elapsed)), y: g.size.height / 2)
                            .help(pace.detail)
                    }
                }
            }
            .frame(height: 7)
            HStack {
                Text(caption).font(.caption).foregroundStyle(t.muted)
                Spacer()
                if let pace {
                    Label(pace.pace.label, systemImage: pace.pace.icon)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(pace.pace.color(t))
                        .help(pace.detail)
                }
            }
        }
    }
}
