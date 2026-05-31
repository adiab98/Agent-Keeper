import SwiftUI
import AgentKeeperCore

struct MenuBarView: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if store.accessibilityNeeded {
                Divider()
                accessibilityBanner
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    section(title: "Needs attention", state: .waiting)
                    section(title: "Working", state: .working)
                    section(title: "Idle", state: .idle)
                    if store.sessions.isEmpty {
                        Text("No active agents")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 24)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            .frame(maxHeight: 480)
            Divider()
            footer
        }
    }

    private var header: some View {
        HStack {
            Text("Agent Keeper").font(.headline)
            Spacer()
            if store.axEnabled {
                Image(systemName: store.axTrusted ? "shield.lefthalf.filled" : "shield.slash")
                    .foregroundStyle(store.axTrusted ? .green : .orange)
                    .help(store.axTrusted
                        ? "Accessibility granted — Desktop “Needs attention” detection active"
                        : "Accessibility NOT granted — Desktop detection disabled")
            }
            Button {
                PreferencesWindowController.shared.show()
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .help("Preferences")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var accessibilityBanner: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.shield.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Accessibility permission needed")
                    .font(.system(size: 12, weight: .semibold))
                Text("Claude Desktop, Codex Desktop & Cowork can’t show “Needs attention” until you grant it. macOS often revokes this after a rebuild.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open Accessibility Settings") { store.requestAccessibility() }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.top, 1)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.12))
    }

    private var footer: some View {
        HStack {
            Button("Reveal Status Folder") {
                NSWorkspace.shared.activateFileViewerSelecting([AppPaths.statusDirectory])
            }
            Spacer()
            Button("Quit") { NSApp.terminate(nil) }
        }
        .buttonStyle(.borderless)
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @AppStorage("agentkeeper.hideStale") private var hideStale: Bool = true

    private func section(title: String, state: AgentState) -> some View {
        let staleThreshold: TimeInterval = 60 * 60 // 1 hour
        let now = Date()
        let allItems = store.sessions.filter { $0.state == state }
        let items: [SessionStatus] = hideStale
            ? allItems.filter { now.timeIntervalSince($0.lastTransitionAt) < staleThreshold || $0.state != .idle }
            : allItems
        return Group {
            if !items.isEmpty {
                Text("\(title.uppercased()) (\(items.count))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(items) { s in
                    SessionRow(status: s)
                        .onTapGesture { store.focus(s) }
                }
            }
        }
    }
}
