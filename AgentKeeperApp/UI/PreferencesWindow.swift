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
    @State private var runningApp = RunningAppInfo.current
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
        .frame(width: 560, height: 480)
        .padding()
        .onReceive(diagTimer) { _ in
            diag = DetectionDiagnostics.shared.snapshot()
            axTrusted = AccessibilityProbe.isTrusted()
        }
    }

    private var general: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                GroupBox("General") {
                    VStack(alignment: .leading, spacing: 10) {
                        Picker("Waiting sound", selection: $soundName) {
                            ForEach(availableSounds, id: \.self) { s in
                                Text(s).tag(s)
                            }
                        }
                        HStack {
                            Button("Preview sound") { NSSound(named: NSSound.Name(soundName))?.play() }
                            Spacer()
                        }
                        Toggle("Hide idle agents after 10 minutes", isOn: $hideStale)
                    }
                }
                accessibilitySection
            }
            .padding(.vertical, 8)
        }
    }

    private var runningAppSection: some View {
        GroupBox("Running App") {
            VStack(alignment: .leading, spacing: 8) {
                metadataRow("Version", "\(runningApp.version) (\(runningApp.build))")
                metadataRow("Bundle ID", runningApp.bundleIdentifier)
                metadataRow("Signing", runningApp.signingSummary)
                metadataRow("Modified", formatted(runningApp.modifiedAt))

                VStack(alignment: .leading, spacing: 3) {
                    Text("Path")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(runningApp.bundleURL.path)
                        .font(.system(size: 11, design: .monospaced))
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .help(runningApp.bundleURL.path)
                }

                HStack {
                    Button("Reveal This App") {
                        NSWorkspace.shared.activateFileViewerSelecting([runningApp.bundleURL])
                    }
                    Button("Copy Path") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(runningApp.bundleURL.path, forType: .string)
                    }
                    Spacer()
                }
            }
        }
    }

    private var accessibilitySection: some View {
        GroupBox("Accessibility") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: axTrusted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(axTrusted ? .green : .orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(axTrusted ? "Permission Granted" : "Permission Not Granted")
                            .font(.system(size: 13, weight: .semibold))
                        Text("Agent Keeper uses Accessibility only for supported desktop agent attention signals.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }

                HStack {
                    Button("Open Accessibility Settings") {
                        openAccessibilitySettings(promptIfNeeded: !axTrusted)
                    }
                    .buttonStyle(.borderedProminent)

                    Button("Re-check") {
                        axTrusted = AccessibilityProbe.isTrusted()
                    }
                    Spacer()
                }

                Divider()

                Toggle("Detect Needs Attention on Desktop apps", isOn: $axEnabled)
                    .onChange(of: axEnabled) { _, newValue in
                        if newValue && !axTrusted {
                            openAccessibilitySettings(promptIfNeeded: true)
                        }
                        axTrusted = AccessibilityProbe.isTrusted()
                    }
                Text(axEnabled
                    ? (axTrusted
                        ? "On: watching Claude Desktop, Claude Cowork, and Codex Desktop for desktop attention signals."
                        : "On, but macOS has not granted Accessibility yet. Enable Agent Keeper in System Settings.")
                    : "Off: desktop apps still show working/idle. Claude Code CLI still gets reliable Needs Attention from its hook."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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

                Divider()
                runningAppSection

                HStack {
                    Button("Reveal status folder") {
                        NSWorkspace.shared.activateFileViewerSelecting([AppPaths.statusDirectory])
                    }
                    Spacer()
                }
                Spacer()
            }
            .padding(.vertical, 8)
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

    private func metadataRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 76, alignment: .leading)
            Text(value)
                .font(.system(size: 12))
                .textSelection(.enabled)
            Spacer()
        }
    }

    private func formatted(_ date: Date?) -> String {
        guard let date else { return "Unknown" }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter.string(from: date)
    }

    private func openAccessibilitySettings(promptIfNeeded: Bool) {
        if promptIfNeeded {
            AccessibilityProbe.requestTrust()
        }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
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
