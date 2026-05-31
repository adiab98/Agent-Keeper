import SwiftUI
import AppKit
import AgentKeeperCore

@MainActor
final class PreferencesWindowController {
    static let shared = PreferencesWindowController()

    private var window: NSWindow?

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let host = NSHostingController(rootView: PreferencesView())
        let w = NSWindow(contentViewController: host)
        w.title = "Agent Keeper Preferences"
        w.styleMask = [.titled, .closable]
        w.isReleasedWhenClosed = false
        w.center()
        self.window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct PreferencesView: View {
    @State private var hookInstalled = HookBinaryInstaller.isInstalled
    @State private var claudeInstalled = ClaudeHookInstaller.isInstalled
    @State private var codexInstalled = CodexNotifyInstaller.isInstalled
    @AppStorage("agentkeeper.sound") private var soundName: String = "Glass"
    @AppStorage("agentkeeper.ax.desktopAttention") private var axEnabled: Bool = false
    @AppStorage("agentkeeper.hideStale") private var hideStale: Bool = true
    @State private var errorText: String?
    @State private var axTrusted: Bool = AccessibilityProbe.isTrusted()

    private let availableSounds = ["Glass", "Hero", "Submarine", "Ping", "Bottle", "Frog", "Funk", "Pop", "Purr", "Tink"]

    @State private var diag: [String: DetectionDiagnostics.ProducerStat] = DetectionDiagnostics.shared.snapshot()
    private let diagTimer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        TabView {
            general
                .tabItem { Label("General", systemImage: "gear") }
            integrations
                .tabItem { Label("Integrations", systemImage: "link") }
            diagnostics
                .tabItem { Label("Diagnostics", systemImage: "stethoscope") }
        }
        .frame(width: 480, height: 360)
        .padding()
    }

    private var general: some View {
        Form {
            Picker("Waiting sound", selection: $soundName) {
                ForEach(availableSounds, id: \.self) { s in
                    Text(s).tag(s)
                }
            }
            HStack {
                Button("Preview sound") { NSSound(named: NSSound.Name(soundName))?.play() }
                Spacer()
            }
            Divider()
            Toggle("Hide sessions idle for more than 1 hour", isOn: $hideStale)
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Toggle("Detect Needs Attention on Desktop apps (Accessibility)", isOn: $axEnabled)
                    .onChange(of: axEnabled) { _, newValue in
                        if newValue && !axTrusted {
                            AccessibilityProbe.requestTrust()
                        }
                        axTrusted = AccessibilityProbe.isTrusted()
                    }
                Text(axEnabled
                    ? (axTrusted
                        ? "On — scanning Claude Desktop and Codex Desktop for pending Approve/Allow buttons."
                        : "On — but Accessibility access not granted yet. Open System Settings → Privacy & Security → Accessibility and enable Agent Keeper.")
                    : "Off — Desktop apps only show working/idle. Claude Code CLI still gets reliable Needs Attention from its hook."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                if axEnabled && !axTrusted {
                    HStack {
                        Button("Open Accessibility Settings") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        Button("Re-check") { axTrusted = AccessibilityProbe.isTrusted() }
                    }
                }
            }
            Divider()
            HStack {
                Button("Reveal status folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([AppPaths.statusDirectory])
                }
                Spacer()
            }
        }
    }

    private var integrations: some View {
        VStack(alignment: .leading, spacing: 16) {
            row(
                title: "Hook helper binary",
                detail: AppPaths.hookBinary.path,
                installed: hookInstalled,
                install: { runOnQueue { try HookBinaryInstaller.install() } },
                uninstall: { HookBinaryInstaller.uninstall(); refresh() }
            )
            row(
                title: "Claude Code CLI hook",
                detail: "Notification hook in ~/.claude/settings.json",
                installed: claudeInstalled,
                install: { runOnQueue { try ClaudeHookInstaller.install() } },
                uninstall: { runOnQueue { try ClaudeHookInstaller.uninstall() } }
            )
            row(
                title: "Codex CLI notify wrapper",
                detail: "notify = wrapper in ~/.codex/config.toml",
                installed: codexInstalled,
                install: { runOnQueue { try CodexNotifyInstaller.install() } },
                uninstall: { runOnQueue { try CodexNotifyInstaller.uninstall() } }
            )

            if let errorText {
                Text(errorText)
                    .font(.callout)
                    .foregroundStyle(.red)
            }
            Spacer()
        }
        .padding(.vertical, 8)
    }

    private var diagnostics: some View {
        let producers: [(String, String)] = [
            ("claude-code", "Claude Code"),
            ("codex-cli", "Codex CLI"),
            ("claude-desktop", "Claude Desktop"),
            ("claude-cowork", "Claude Cowork"),
            ("codex-desktop", "Codex Desktop"),
        ]
        return ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                health("Accessibility permission", axTrusted,
                       ok: "Granted", bad: "Not granted — Desktop waiting detection disabled")
                health("Hook binary installed", HookBinaryInstaller.isInstalled)
                health("Claude Code notification hook", ClaudeHookInstaller.isInstalled)
                health("Codex notify wrapper", CodexNotifyInstaller.isHealthy,
                       ok: "Healthy", bad: CodexNotifyInstaller.isInstalled
                            ? "Self-referential — re-launch to repair"
                            : "Not installed")
                Divider()
                Text("PRODUCERS").font(.caption).foregroundStyle(.secondary)
                ForEach(producers, id: \.0) { key, title in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(.system(size: 12, weight: .semibold))
                        if let s = diag[key] {
                            Text("last scan \(rel(s.lastScanAt)) · found \(s.discovered) · wrote \(s.written) · errors \(s.errors)")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                            if let e = s.lastError {
                                Text("⚠︎ \(e) (\(rel(s.lastErrorAt)))")
                                    .font(.system(size: 11)).foregroundStyle(.orange)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        } else {
                            Text("no scans yet").font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                }
                Spacer()
            }
            .padding(.vertical, 8)
        }
        .onReceive(diagTimer) { _ in
            diag = DetectionDiagnostics.shared.snapshot()
            axTrusted = AccessibilityProbe.isTrusted()
        }
    }

    private func health(_ title: String, _ ok: Bool, ok okText: String = "OK", bad badText: String = "Missing") -> some View {
        HStack(spacing: 8) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(ok ? .green : .orange)
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(.system(size: 12, weight: .semibold))
                Text(ok ? okText : badText).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private func rel(_ date: Date?) -> String {
        guard let date else { return "never" }
        let secs = Int(Date().timeIntervalSince(date))
        if secs < 2 { return "just now" }
        if secs < 60 { return "\(secs)s ago" }
        return "\(secs / 60)m ago"
    }

    private func row(title: String, detail: String, installed: Bool, install: @escaping () -> Void, uninstall: @escaping () -> Void) -> some View {
        HStack(alignment: .top) {
            Image(systemName: installed ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(installed ? .green : .secondary)
                .font(.system(size: 16))
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
                    .lineLimit(2).truncationMode(.middle)
            }
            Spacer()
            if installed {
                Button("Uninstall", role: .destructive, action: uninstall)
            } else {
                Button("Install", action: install)
            }
        }
    }

    private func runOnQueue(_ block: @escaping () throws -> Void) {
        errorText = nil
        DispatchQueue.global(qos: .userInitiated).async {
            var err: String?
            do { try block() } catch { err = error.localizedDescription }
            DispatchQueue.main.async {
                errorText = err
                refresh()
            }
        }
    }

    private func refresh() {
        hookInstalled = HookBinaryInstaller.isInstalled
        claudeInstalled = ClaudeHookInstaller.isInstalled
        codexInstalled = CodexNotifyInstaller.isInstalled
    }
}
