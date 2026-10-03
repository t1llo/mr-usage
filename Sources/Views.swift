// The panel that drops down from the menu bar. A provider picker (Claude or OpenAI) in the header,
// then two tabs: Limits (session as a numeric hero, other limits as bars, each with an even-pace
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
    var detail: String { self == .claude ? "Claude Code, OpenCode, Pi" : "Codex CLI, OpenCode, Pi" }
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
    @ObservedObject var layout: MenuPanelLayout
    @AppStorage("theme") private var themeID = Theme.tokyoNight.id
    @AppStorage("tab") private var tab: PanelTab = .limits
    @AppStorage("provider") private var provider: Provider = .claude
    @State private var picking = false
    @State private var choosingTheme = false
    @State private var showingSettings = false
    @State private var openAtLogin = SMAppService.mainApp.status == .enabled

    private var t: Theme { Theme.named(themeID) }
    private var page: String { showingSettings ? "settings" : "\(provider.rawValue)/\(tab.rawValue)" }

    var body: some View {
        PanelViewport(layout: layout, page: page, fitsContent: !showingSettings && tab == .limits) {
            VStack(alignment: .leading, spacing: 12) {
                header
                Segmented(options: PanelTab.allCases, selection: Binding(
                    get: { tab },
                    set: { tab = $0; showingSettings = false }
                ), fill: true, showsSelection: !showingSettings, isTabBar: true) { $0.rawValue }
                .frame(height: 28)
            }
        } content: {
            VStack(alignment: .leading, spacing: 12) {
                if showingSettings {
                    claudeLoginSettings
                    LeaderboardSettingsView(leaderboard: leaderboard)
                } else {
                    tabContent
                    if provider == .claude, tab == .limits, store.displayUsage() != nil, store.lastError != nil, !store.inFlight {
                        ErrorBanner(text: store.status)
                    }
                }
            }
        } footer: {
            footer
        }
        .background(background)
        .foregroundStyle(t.text)
        .fontWeight(.medium)
        .tint(t.accent)
        .environment(\.theme, t)
        .environment(\.colorScheme, t.isDark ? .dark : .light)
        .preferredColorScheme(t.isDark ? .dark : .light)
        .onChange(of: layout.isPresented) { presented in
            if presented { store.tick(); tokens.refresh() }
            else { picking = false; choosingTheme = false }
        }
        .onExitCommand {
            if picking { picking = false }
            else if choosingTheme { choosingTheme = false }
            else if showingSettings { showingSettings = false }
            else { layout.dismiss() }
        }
        .onChange(of: tab) { if $0 == .tokens { tokens.refresh() } }
        .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { _ in
            if layout.isPresented && tab == .tokens && !showingSettings { tokens.refresh() }
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

    private var background: some View { PanelBackground() }

    private var header: some View {
        HStack(spacing: 8) {
            if showingSettings {
                AppIcon().frame(width: 24, height: 24)
                Text("Settings").font(.system(size: 15, weight: .semibold))
            } else {
                providerPicker
            }
            Spacer(minLength: 0)
            HStack(spacing: 4) {
                Button { choosingTheme.toggle() } label: {
                    Image(systemName: "circle.lefthalf.filled")
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
                        .background(t.base.opacity(0.85))
                        .environment(\.theme, t)
                        .environment(\.colorScheme, t.isDark ? .dark : .light)
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
                    Image(systemName: showingSettings ? "xmark" : "gearshape")
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
            HStack(spacing: 8) {
                AppIcon().frame(width: 24, height: 24)
                Text(provider.rawValue).font(.system(size: 15, weight: .semibold)).tracking(-0.3)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(t.muted)
                    .rotationEffect(.degrees(picking ? 180 : 0))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Switch provider")
        .accessibilityLabel("\(provider.rawValue) usage. Switch provider")
        .popover(isPresented: $picking, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Provider.allCases) { p in
                    Button { choose(p) } label: {
                        HStack(spacing: 8) {
                            Image(systemName: p.icon).foregroundStyle(t.subtext).frame(width: 16)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(p.rawValue).font(.system(size: 12, weight: .semibold))
                                Text(p.detail).font(.caption).foregroundStyle(t.muted)
                            }
                            Spacer(minLength: 12)
                            if p == provider { Image(systemName: "checkmark").foregroundStyle(t.accent) }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(p == provider ? t.text.opacity(0.06) : .clear))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(6)
            .frame(width: 230)
            .foregroundStyle(t.text)
            .background(t.base.opacity(0.85))
            .environment(\.theme, t)
            .environment(\.colorScheme, t.isDark ? .dark : .light)
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
        if let u = store.displayUsage(now: now) {
            VStack(alignment: .leading, spacing: 10) {
                limitCards(u, now: now)
                if let at = store.lastGoodAt {
                    Text("\(store.inFlight ? "Refreshing · " : "")Last reading \(dayClock(at))").font(.system(size: 10)).foregroundStyle(t.muted)
                        .frame(maxWidth: .infinity)
                }
            }
        } else {
            EmptyState(loading: store.inFlight, text: store.status)
        }
        if let label = store.authLabel {
            Text(label).font(.system(size: 10)).foregroundStyle(t.muted)
                .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity)
        }
    }

    private var claudeLoginSettings: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Text("Claude limits login").font(.system(size: 14, weight: .semibold))
                Picker("Saved login", selection: Binding(get: { store.loginSource }, set: { store.setLoginSource($0) })) {
                    ForEach(ClaudeLoginSource.allCases) { Text($0.rawValue).tag($0) }
                }.disabled(store.inFlight)
                Text(store.authLabel ?? "No saved login selected yet").foregroundStyle(t.subtext)
                if store.loginSource == .claudeCode || store.loginSource == .automatic {
                    Text("CLI profile: \(store.configDirectory.path)").textSelection(.enabled)
                    HStack {
                        Button("Choose profile folder…") { chooseClaudeProfile() }
                        Button("Default") { store.setConfigDirectory(ClaudePaths.defaultDirectory) }
                    }.disabled(store.inFlight)
                }
                Text("Select the tool/profile logged into your personal or Team account. Desktop’s login is separate and cannot supply CLI OAuth limits. Log tracking works without a login; API-key usage has no subscription limits.")
                    .foregroundStyle(t.muted)
            }.font(.system(size: 10)).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func chooseClaudeProfile() {
        layout.dismiss()
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            let panel = NSOpenPanel()
            panel.title = "Choose Claude Code configuration folder"
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.allowsMultipleSelection = false
            panel.showsHiddenFiles = true
            panel.directoryURL = store.configDirectory
            panel.begin { response in
                guard response == .OK, let url = panel.url else { return }
                store.setConfigDirectory(url)
                tokens.refresh()
            }
        }
    }

    @ViewBuilder private func openAILimits(now: Date) -> some View {
        if let cx = tokens.codexLimits {
            VStack(alignment: .leading, spacing: 10) {
                limitCards(cx.current(now: now), now: now)
                if let credits = tokens.codexCredits { OpenAICreditsCard(credits: credits) }
                Text([cx.plan.map { "ChatGPT " + planName($0) }, cx.live ? "updated \(dayClock(cx.asOf))" : "from Codex logs, \(dayClock(cx.asOf))"]
                        .compactMap { $0 }.joined(separator: " · "))
                    .font(.caption2).foregroundStyle(t.muted)
                    .frame(maxWidth: .infinity)
                    .help(cx.live ? "Fetched from ChatGPT with Codex or OpenCode’s login"
                          : "Codex logs your plan's limits with every request, so use elsewhere (OpenCode, ChatGPT) shows up after your next Codex request.")
                if let e = tokens.liveError { ErrorBanner(text: "Live limits unavailable: \(e). Showing the last reading.") }
                if let h = tokens.planHistory { PlanHistoryCard(history: h) }
            }
        } else {
            EmptyState(loading: tokens.checkingLive || !tokens.loaded, text: tokens.checkingLive ? "Fetching ChatGPT limits…"
                : tokens.liveError.map { "Live limits unavailable: \($0). API-key logins have no subscription limits." }
                ?? (!tokens.loaded ? "Reading local usage…"
                    : "No subscription limits yet. Sign in to Codex or OpenCode with your ChatGPT account. API-key logins have no subscription limits."))
        }
    }

    private func limitCards(_ u: Usage, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let session = u.limits.first { SessionCard(limit: session, now: now) }
            let weekly = Array(u.limits.dropFirst())
            if !weekly.isEmpty {
                Card {
                    VStack(alignment: .leading, spacing: 20) {
                        ForEach(weekly) { l in
                            BarRow(label: l.label, pct: l.pct,
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
                    BarRow(label: "Extra usage", pct: pct,
                           value: "\(money(c.usedCents)) / \(c.limitCents.map(money) ?? "no limit")",
                           caption: "Resets \(firstOfNextMonth())", pace: nil)
                }
            }
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
        .font(.system(size: 10))
        .padding(.horizontal, 2)
        .padding(.top, 10)
        .overlay(alignment: .top) { Rectangle().fill(t.border.opacity(0.6)).frame(height: 0.5) }
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
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(t.card))
            .shadow(color: .black.opacity(t.isDark ? 0.025 : 0.035), radius: 8, y: 3)
    }
}

struct PaceLabel: View {
    let info: PaceInfo
    @Environment(\.theme) private var t

    var body: some View {
        let c = info.pace.color(t)
        HStack(spacing: 5) {
            Circle().fill(c.opacity(0.85)).frame(width: 4, height: 4)
            Text(info.pace.label).font(.system(size: 10)).foregroundStyle(t.subtext)
        }
        .help(info.detail)
    }
}

struct ErrorBanner: View {
    let text: String
    @Environment(\.theme) private var t

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.circle")
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .font(.caption)
        .foregroundStyle(t.warn)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(t.warn.opacity(0.065)))
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
                Image(systemName: "chart.xyaxis.line")
                    .font(.title3)
                    .foregroundStyle(t.muted)
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

/// One clear readout, with reset details and an even-pace marker on a quiet progress track.
struct SessionCard: View {
    let limit: Limit
    let now: Date
    @Environment(\.theme) private var t

    var body: some View {
        let info = limit.pace(now: now)
        Card {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text(limit.label)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(t.subtext)
                    Spacer()
                    if let info { PaceLabel(info: info) }
                }
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text("\(Int(limit.pct))")
                        .font(.system(size: 38, weight: .semibold).monospacedDigit())
                        .tracking(-1.5)
                        .contentTransition(.numericText())
                    Text("%")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(t.muted)
                    Spacer()
                    VStack(alignment: .trailing, spacing: 3) {
                        Text(limit.resetsAt == nil ? "Ready" : remaining(to: limit.resetsAt, now: now))
                            .font(.system(size: 13, weight: .semibold).monospacedDigit())
                            .foregroundStyle(t.subtext)
                        Text(limit.resetsAt == nil ? "No active session" : "until reset")
                            .font(.system(size: 10)).foregroundStyle(t.muted)
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    LimitMeter(pct: limit.pct, marker: info?.elapsed)
                    Text(limit.resetsAt == nil ? "Starts with your next message" : "Resets at \(resetClock(limit.resetsAt))")
                        .font(.system(size: 10)).foregroundStyle(t.muted)
                }
            }
        }
    }
}

/// Shared by the session hero and other limits; the fine tick marks even-paced usage.
struct LimitMeter: View {
    let pct: Double
    let marker: Double?
    @Environment(\.theme) private var t
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let color = t.level(pct)
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(t.track)
                Capsule()
                    .fill(LinearGradient(colors: [color.opacity(0.55), color], startPoint: .leading, endPoint: .trailing))
                    .frame(width: pct > 0 ? max(4, g.size.width * min(1, pct / 100)) : 0)
                    .shadow(color: color.opacity(0.12), radius: 4, y: 1)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.4), value: pct)
                if let marker {
                    RoundedRectangle(cornerRadius: 0.5)
                        .fill(t.text.opacity(0.55))
                        .frame(width: 1.5, height: 11)
                        .position(x: max(1, min(g.size.width - 1, g.size.width * marker)), y: g.size.height / 2)
                }
            }
        }
        .frame(height: 6)
    }
}

// MARK: - OpenAI credits

struct OpenAICreditsCard: View {
    let credits: CodexCredits
    @Environment(\.theme) private var t

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Text("Credit balance")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(t.subtext)
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(credits.displayBalance)
                        .font(.system(size: 28, weight: .semibold).monospacedDigit())
                        .tracking(-0.6)
                        .foregroundStyle(t.text)
                        .contentTransition(.numericText())
                    if !credits.unlimited, credits.balance != nil {
                        Text("credits").font(.caption).foregroundStyle(t.subtext)
                    }
                }
                Text("Used after your plan's included usage.")
                    .font(.system(size: 10)).foregroundStyle(t.muted)
                Text("\(credits.live ? "Updated" : "From Codex logs ·") \(dayClock(credits.asOf))")
                    .font(.system(size: 10)).foregroundStyle(t.muted)
            }
        }
        .help("OpenAI usage credits, including grants reflected in your balance. Separate from estimated API costs.")
    }
}

// MARK: - Bars

struct BarRow: View {
    let label: String
    let pct: Double
    let value: String
    let caption: String
    let pace: PaceInfo?
    @Environment(\.theme) private var t

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Text(label).font(.system(size: 12, weight: .medium)).foregroundStyle(t.subtext)
                Spacer()
                Text(value)
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .contentTransition(.numericText())
            }
            LimitMeter(pct: pct, marker: pace?.elapsed)
            Text(caption).font(.system(size: 10)).foregroundStyle(t.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .help(pace?.detail ?? caption)
    }
}
