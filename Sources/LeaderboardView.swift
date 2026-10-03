import SwiftUI

struct LeaderboardSettingsView: View {
    @ObservedObject var leaderboard: LeaderboardStore
    @Environment(\.theme) private var t
    @State private var name = ""
    @FocusState private var editingName: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Card {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Leaderboard")
                        .font(.system(size: 14, weight: .semibold))
                    Text("Choose the name people see next to your usage.")
                        .font(.caption).foregroundStyle(t.subtext).fixedSize(horizontal: false, vertical: true)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Display name").font(.system(size: 10)).foregroundStyle(t.muted)
                        TextField("Your leaderboard name", text: $name)
                            .textFieldStyle(.plain).font(.system(size: 12))
                            .focused($editingName)
                            .padding(10)
                            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(t.track.opacity(0.55)))
                            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(editingName ? t.accent.opacity(0.6) : .clear, lineWidth: 1))
                            .onSubmit { save() }
                    }
                }
            }
            Card {
                VStack(alignment: .leading, spacing: 14) {
                    Toggle("Share on leaderboard", isOn: Binding(
                        get: { leaderboard.state.enabled && !leaderboard.needsConsent },
                        set: { on in
                            if on { leaderboard.enable(name: name) }
                            else { leaderboard.disable() }
                        }))
                        .font(.system(size: 12, weight: .medium))
                        .toggleStyle(.switch).controlSize(.small)
                        .disabled(leaderboard.state.pendingRemoval)
                    sharingDetails
                    if leaderboard.needsConsent {
                        Button("Remove previous profile") { leaderboard.disable() }
                            .buttonStyle(PanelActionButtonStyle())
                    }
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(leaderboard.status).foregroundStyle(t.subtext)
                if let error = leaderboard.lastError { Text(error).foregroundStyle(t.warn) }
                if let origin = website {
                    Link(destination: origin.appendingPathComponent("leaderboard")) {
                        Label("Open leaderboard", systemImage: "arrow.up.right")
                    }
                    .foregroundStyle(t.accent).padding(.top, 3)
                }
            }
            .font(.system(size: 10))
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 2)
        }
        .onAppear {
            name = leaderboard.state.displayName
        }
        .onChange(of: editingName) { focused in if !focused && hasChanges { save() } }
        .onDisappear { if hasChanges { save() } }
    }

    private var hasChanges: Bool {
        name != leaderboard.state.displayName
    }

    private var website: URL? {
        // Existing profiles keep their original origin for updates and removal.
        if leaderboard.state.enabled || leaderboard.state.pendingRemoval {
            return try? leaderboardOrigin(leaderboard.state.website)
        }
        return LeaderboardConfiguration.origin
    }

    private var sharingDetails: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Shares all Claude and OpenAI usage under your name at \((website ?? LeaderboardConfiguration.origin).host ?? "the leaderboard"). Includes supported local tools and OpenAI All devices totals, counted once.")
                .foregroundStyle(t.muted)
                .fixedSize(horizontal: false, vertical: true)
            PanelDisclosure(title: "Exactly what gets shared") {
                VStack(alignment: .leading, spacing: 12) {
                    sharingDetail("Uploaded fields", """
                    • Your chosen display name.
                    • UTC date, provider (Claude or OpenAI) and model ID for each daily total.
                    • The website’s API-value board category (legacy name: Subscription); not a billing claim.
                    • Uncached input token count.
                    • Output token count, including reasoning.
                    • Cache-read token count.
                    • Cache-write counts, split into 5-minute and 1-hour writes.
                    • Whether token splits and costs come from All devices estimates.
                    """)
                    sharingDetail("Connection data", "A random, leaderboard-only authentication token, data-format version and sharing-consent flag are also sent. Requests include an app identifier; the server also sees your IP address.")
                    sharingDetail("Counted once", "OpenAI uses account-wide daily totals when available. Local Codex/OpenCode/Pi logs fill only unreported UTC days and are replaced when account totals arrive. Token-kind and model splits are estimated, just like All devices in the app. Claude uses local Claude Code, OpenCode and Pi logs, not the lifetime /stats cache. Logs cannot reliably identify billing or accounts; values are API-price equivalents, not verified spending.")
                    sharingDetail("Shown publicly", "Your name, rank, total tokens, estimated API value/spend, providers, All devices coverage, active days, recent daily usage and last sync time. The website calculates dollar estimates from the counts; these are not subscription charges or verified bills.")
                    sharingDetail("History and removal", "Syncs about every 5 minutes. Starts with the last 30 UTC days and retains older daily totals for all-time rankings. All supported providers are included. Turning sharing off requests deletion of your profile and uploaded totals; offline removals retry when connected.")
                    sharingDetail("Not uploaded", "Prompts, responses, code, file or project paths, session or request IDs, provider API keys or login tokens, plan limits, credit balances, or payment details.")
                }
            }
        }
        .font(.system(size: 11))
    }

    private func sharingDetail(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).fontWeight(.medium).foregroundStyle(t.subtext)
            Text(text).foregroundStyle(t.muted).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func save() {
        leaderboard.saveProfile(name: name)
        if leaderboard.lastError == nil { name = leaderboard.state.displayName }
    }
}
