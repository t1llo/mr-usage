import SwiftUI

struct LeaderboardSettingsView: View {
    @ObservedObject var leaderboard: LeaderboardStore
    @Environment(\.theme) private var t
    @State private var name = ""
    @State private var claude: LeaderboardBilling = .unclassified
    @State private var codex: LeaderboardBilling = .unclassified

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Card {
                VStack(alignment: .leading, spacing: 12) {
                    Label("Leaderboard", systemImage: "trophy.fill")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(t.accent)
                    Text("Choose the name people see next to your usage.")
                        .font(.caption).foregroundStyle(t.subtext).fixedSize(horizontal: false, vertical: true)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Display name").font(.caption.weight(.medium))
                        TextField("Your leaderboard name", text: $name).textFieldStyle(.roundedBorder)
                            .onSubmit { save() }
                    }
                    billingPicker("Claude Code", selection: $claude)
                    billingPicker("Codex", selection: $codex)
                    Text("Choose how each tool’s history was billed. Leave mixed or unknown usage unshared. Changes apply to all retained shared history.")
                        .font(.system(size: 10)).foregroundStyle(t.muted).fixedSize(horizontal: false, vertical: true)
                    Button("Save profile") { save() }
                        .controlSize(.small)
                        .disabled(!hasChanges || leaderboard.inFlight || leaderboard.state.pendingRemoval)
                    Rectangle().fill(t.border.opacity(0.6)).frame(height: 0.5)
                    Toggle("Share on leaderboard", isOn: Binding(
                        get: { leaderboard.state.enabled },
                        set: { on in
                            if on { leaderboard.enable(name: name, claude: claude, codex: codex) }
                            else { leaderboard.disable() }
                        }))
                        .toggleStyle(.switch).controlSize(.small)
                        .disabled(leaderboard.state.pendingRemoval)
                    sharingDetails
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(leaderboard.status).foregroundStyle(t.subtext)
                if let error = leaderboard.lastError { Text(error).foregroundStyle(t.warn) }
                if let origin = website {
                    Link(destination: origin.appendingPathComponent("leaderboard")) {
                        Label("Open leaderboard", systemImage: "arrow.up.right.square")
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
            claude = leaderboard.state.claudeBilling
            codex = leaderboard.state.codexBilling
        }
    }

    private var hasChanges: Bool {
        name != leaderboard.state.displayName || claude != leaderboard.state.claudeBilling || codex != leaderboard.state.codexBilling
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
            Text("Sends your display name and daily token counts, grouped by tool, model and billing category, to \((website ?? LeaderboardConfiguration.origin).host ?? "the leaderboard").")
                .foregroundStyle(t.muted)
                .fixedSize(horizontal: false, vertical: true)
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 12) {
                    sharingDetail("Uploaded fields", """
                    • Your chosen display name.
                    • UTC date, tool (Claude Code or Codex) and model ID for each daily total.
                    • Your billing category: Subscription or API billed.
                    • Uncached input token count.
                    • Output token count, including reasoning.
                    • Cache-read token count.
                    • Cache-write counts, split into 5-minute and 1-hour writes.
                    """)
                    sharingDetail("Connection data", "A random, leaderboard-only authentication token, data-format version and sharing-consent flag are also sent. Requests include an app identifier; the server also sees your IP address.")
                    sharingDetail("Shown publicly", "Your name, rank, total tokens, estimated API value/spend, tools used, active days, recent daily usage and last sync time. The website calculates dollar estimates from the counts; these are not subscription charges or verified bills.")
                    sharingDetail("History and removal", "Syncs about every 5 minutes. Starts with the last 30 UTC days and retains older daily totals for all-time rankings. Tools set to Not shared are excluded. Turning sharing off requests deletion of your profile and uploaded totals; offline removals retry when connected.")
                    sharingDetail("Not uploaded", "Prompts, responses, code, file or project paths, session or request IDs, provider API keys or login tokens, plan limits, payment details, OpenCode usage, or ChatGPT All devices estimates.")
                }
                .padding(.top, 8)
            } label: {
                Text("Exactly what gets shared")
                    .fontWeight(.semibold)
                    .foregroundStyle(t.accent)
            }
            .tint(t.accent)
        }
        .font(.system(size: 11))
    }

    private func sharingDetail(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).fontWeight(.semibold).foregroundStyle(t.subtext)
            Text(text).foregroundStyle(t.muted).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func billingPicker(_ label: String, selection: Binding<LeaderboardBilling>) -> some View {
        HStack {
            Text(label).font(.caption.weight(.medium))
            Spacer()
            Picker(label, selection: selection) {
                ForEach(LeaderboardBilling.allCases) { mode in Text(mode.label).tag(mode) }
            }
            .labelsHidden().pickerStyle(.menu).frame(width: 135).controlSize(.small)
            .disabled(leaderboard.state.pendingRemoval)
        }
    }

    private func save() {
        leaderboard.saveProfile(name: name, claude: claude, codex: codex)
        if leaderboard.lastError == nil { name = leaderboard.state.displayName }
    }
}
