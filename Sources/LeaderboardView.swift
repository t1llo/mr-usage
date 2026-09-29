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
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(leaderboard.status).foregroundStyle(t.subtext)
                if let error = leaderboard.lastError { Text(error).foregroundStyle(t.warn) }
                Text("Shares your name and daily Claude Code/Codex token totals by model. Prompts, code, keys and OpenCode logs stay local. Starts with 30 days; older shared totals are retained until you leave.")
                    .foregroundStyle(t.muted)
                Text("Subscription dollars are API-equivalent value; API dollars are estimates, not verified bills.")
                    .foregroundStyle(t.muted)
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
