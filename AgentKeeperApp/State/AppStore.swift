import Foundation
import Combine
import AppKit
import AgentKeeperCore

@MainActor
final class AppStore: ObservableObject {
    @Published private(set) var sessions: [SessionStatus] = []
    @Published private(set) var overallState: AgentState = .idle

    /// Whether the user turned on Desktop "Needs Attention" detection, and
    /// whether macOS has actually granted us Accessibility. Refreshed on the 1s
    /// sweep so the UI reflects the live TCC state — important because ad-hoc
    /// Debug builds get a fresh code signature each build and macOS revokes the
    /// grant, leaving the feature silently dead until re-granted.
    @Published private(set) var axEnabled: Bool = false
    @Published private(set) var axTrusted: Bool = false

    /// True when the feature is on but the permission is missing — the one
    /// state worth nagging the user about.
    var accessibilityNeeded: Bool { axEnabled && !axTrusted }

    private let store = StatusStore()
    private var watcher: StatusDirectoryWatcher?
    private var claudeWatcher: ClaudeSessionsWatcher?
    private var codexProducer: CodexCLIProducer?
    private var codexDesktopProducer: CodexDesktopProducer?
    private var claudeDesktopProducer: ClaudeDesktopProducer?
    private var claudeCoworkProducer: ClaudeCoworkProducer?
    private var alertCenter = AlertCenter()
    private var sweepTimer: DispatchSourceTimer?

    init() {
        AppPaths.bootstrap()
        loadInitial()
        refreshAXStatus()
        startWatching()
        startProducers()
        startLivenessSweep()
        startActivationObserver()
    }

    /// Re-reads the toggle + live Accessibility trust state. Cheap (one
    /// UserDefaults read + one `AXIsProcessTrusted()` call).
    private func refreshAXStatus() {
        let enabled = UserDefaults.standard.bool(forKey: "agentkeeper.ax.desktopAttention")
        let trusted = AccessibilityProbe.isTrusted()
        if enabled != axEnabled { axEnabled = enabled }
        if trusted != axTrusted { axTrusted = trusted }
    }

    /// Opens System Settings at the Accessibility pane (and prompts if we've
    /// never asked), so the menu-bar banner can route the user straight there.
    func requestAccessibility() {
        if !AccessibilityProbe.isTrusted() {
            AccessibilityProbe.requestTrust()
        }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    private var activationObserver: NSObjectProtocol?

    private func startActivationObserver() {
        let nc = NSWorkspace.shared.notificationCenter
        activationObserver = nc.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self,
                  let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            else { return }
            self.clearWaitingForApp(app)
        }
    }

    /// True if the given session's process belongs to (or is a descendant of)
    /// the given app, OR the app's currently focused window title references
    /// this session's display name. Three signals:
    ///   1. Direct pid match.
    ///   2. Bundle-id match anywhere up the PPID chain (helper-process terms).
    ///   3. Focused window title contains the session's displayName — handles
    ///      daemon-spawned processes (Claude Code reparents workers to
    ///      launchd, breaking signals 1 and 2).
    private func sessionBelongsToApp(_ session: SessionStatus, app: NSRunningApplication) -> Bool {
        if let pid = session.pid,
           ProcessTree.isDescendant(pid, ofAppPid: app.processIdentifier, orBundleId: app.bundleIdentifier) {
            return true
        }
        // Window-title fallback. Only consider terminal-ish apps to avoid
        // false positives — e.g., a chat app whose title happens to contain
        // "add-advice-presets" shouldn't clear that session.
        if isTerminalApp(app),
           let title = AccessibilityProbe.focusedWindowTitle(of: app.processIdentifier) {
            let needle = session.displayName
            if !needle.isEmpty && title.localizedCaseInsensitiveContains(needle) {
                return true
            }
        }
        return false
    }

    private func isTerminalApp(_ app: NSRunningApplication) -> Bool {
        guard let bid = app.bundleIdentifier?.lowercased() else { return false }
        let knownTerminals: Set<String> = [
            "com.mitchellh.ghostty",
            "com.apple.terminal",
            "com.googlecode.iterm2",
            "dev.warp.warp-mac",
            "co.zeit.hyper",
            "io.alacritty",
            "net.kovidgoyal.kitty",
            "com.github.wez.wezterm",
        ]
        if knownTerminals.contains(bid) { return true }
        // Heuristic: anything whose bundle id contains "terminal" / "term".
        return bid.contains("terminal") || bid.contains("term")
    }

    /// When the user brings a terminal (or any app) to the front, drop the
    /// `.waiting` flag on Claude Code sessions whose process is a descendant.
    /// This is what makes the red badge clear when you actually go look.
    private func clearWaitingForApp(_ app: NSRunningApplication) {
        var changed = false
        for s in sessions where s.state == .waiting && s.agent == .claudeCode {
            if sessionBelongsToApp(s, app: app) {
                let cleared = SessionStatus(
                    agent: s.agent,
                    sessionId: s.sessionId,
                    displayName: s.displayName,
                    projectPath: s.projectPath,
                    pid: s.pid,
                    state: .idle,
                    lastTransitionAt: Date(),
                    lastHeartbeatAt: Date(),
                    lastEvent: s.lastEvent
                )
                try? store.write(cleared)
                changed = true
            }
        }
        if changed { refresh() }
    }

    private func loadInitial() {
        sessions = store.readAll()
        overallState = computeOverallState(sessions)
    }

    /// Force an immediate re-scan from disk. Cheap (just a directory listing
    /// + decode) so it's fine to call on every popover open.
    func refreshFromDisk() {
        refresh()
    }

    private func startWatching() {
        watcher = StatusDirectoryWatcher(directory: AppPaths.statusDirectory) { [weak self] in
            Task { @MainActor in self?.refresh() }
        }
        watcher?.start()
    }

    private func startProducers() {
        claudeWatcher = ClaudeSessionsWatcher(store: store)
        claudeWatcher?.start()
        codexProducer = CodexCLIProducer(store: store)
        codexProducer?.start()
        codexDesktopProducer = CodexDesktopProducer(store: store)
        codexDesktopProducer?.start()
        claudeDesktopProducer = ClaudeDesktopProducer(store: store)
        claudeDesktopProducer?.start()
        claudeCoworkProducer = ClaudeCoworkProducer(store: store)
        claudeCoworkProducer?.start()
    }

    private func startLivenessSweep() {
        // DispatchSourceTimer on the main queue fires reliably regardless of
        // RunLoop mode — required for menu-bar-only apps where the default
        // runloop mode isn't always pumped while the popover is closed.
        // 1s cadence: refresh is cheap (one dir listing + small JSON decodes).
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + 1.0, repeating: .seconds(1), leeway: .milliseconds(100))
        t.setEventHandler { [weak self] in self?.sweep() }
        t.resume()
        sweepTimer = t
    }

    private func refresh() {
        let next = store.readAll().sorted { lhs, rhs in
            if lhs.state.sortOrder != rhs.state.sortOrder {
                return lhs.state.sortOrder < rhs.state.sortOrder
            }
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
        let previousWaiting = Set(sessions.filter { $0.state == .waiting }.map(\.id))
        let nowWaiting = next.filter { $0.state == .waiting && !previousWaiting.contains($0.id) }
        // Suppress only the notification/sound when the user is already in
        // the relevant terminal — the red row itself ALWAYS surfaces so the
        // user can see Claude is waiting at a glance.
        let front = NSWorkspace.shared.frontmostApplication
        let nowWaitingFiltered = nowWaiting.filter { candidate in
            guard let front, candidate.agent == .claudeCode else { return true }
            return !sessionBelongsToApp(candidate, app: front)
        }
        sessions = next
        overallState = computeOverallState(next)
        for newly in nowWaitingFiltered {
            alertCenter.fire(for: newly)
        }
    }

    private func computeOverallState(_ list: [SessionStatus]) -> AgentState {
        if list.contains(where: { $0.state == .waiting }) { return .waiting }
        if list.contains(where: { $0.state == .working }) { return .working }
        return .idle
    }

    private func sweep() {
        refreshAXStatus()
        for s in sessions {
            if let pid = s.pid, !PIDLivenessProbe.isAlive(pid) {
                store.remove(s.id)
            }
        }
        // No continuous frontmost-based clearing: we want the red row to
        // persist until the user takes an explicit action (clicks the row,
        // activates the terminal from elsewhere, or Claude resumes work).
        refresh()
    }

    func focus(_ s: SessionStatus) {
        // Clicking a row is an explicit acknowledgement — clear `.waiting`
        // immediately even if the process-tree heuristic can't prove the
        // user actually went to the right window. This is the manual
        // fallback for daemon-spawned processes whose ancestry can't be
        // walked back to a terminal.
        if s.state == .waiting {
            let cleared = SessionStatus(
                agent: s.agent,
                sessionId: s.sessionId,
                displayName: s.displayName,
                projectPath: s.projectPath,
                pid: s.pid,
                state: .idle,
                lastTransitionAt: Date(),
                lastHeartbeatAt: Date(),
                lastEvent: s.lastEvent
            )
            try? store.write(cleared)
            refresh()
        }
        if let pid = s.pid,
           let app = NSRunningApplication(processIdentifier: pid) {
            app.activate(options: [.activateIgnoringOtherApps])
            return
        }
        switch s.agent {
        case .claudeDesktop, .claudeCowork:
            launchByBundleId("com.anthropic.claudefordesktop")
        case .codexDesktop:
            launchByBundleId("com.openai.codex")
        default: break
        }
    }

    private func launchByBundleId(_ bid: String) {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bid)
        if let a = apps.first {
            a.activate(options: [.activateIgnoringOtherApps])
        } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid) {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
        }
    }
}

extension AgentState {
    var sortOrder: Int {
        switch self {
        case .waiting: return 0
        case .working: return 1
        case .idle: return 2
        }
    }
}
