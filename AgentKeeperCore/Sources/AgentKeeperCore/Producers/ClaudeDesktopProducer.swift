import Foundation
import AppKit

/// Tracks the Claude Desktop app (com.anthropic.claudefordesktop).
///
/// v1: detect running, infer working/idle from bridge-state.json mtime changes.
/// bridge-state.json gets rewritten whenever the desktop app processes a
/// turn (its `processedMessageUuids` array grows). No notification hook
/// available — `waiting` is not synthesized for Desktop.
public final class ClaudeDesktopProducer {
    private let bundleId = "com.anthropic.claudefordesktop"
    private let store: StatusStore
    private let queue = DispatchQueue(label: "agentkeeper.claude-desktop")
    private var timer: DispatchSourceTimer?

    private var lastBridgeMTime: Date = .distantPast
    private var lastActivityAt: Date = .distantPast

    private var axEnabled: Bool {
        UserDefaults.standard.bool(forKey: "agentkeeper.ax.desktopAttention")
    }

    public init(store: StatusStore) {
        self.store = store
    }

    public func start() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1.0, repeating: .seconds(DetectionTuning.claudeDesktopPoll))
        t.setEventHandler { [weak self] in self?.scan() }
        t.resume()
        timer = t
    }

    public func stop() {
        timer?.cancel(); timer = nil
    }

    deinit { stop() }

    private func scan() {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
        guard let app = apps.first else {
            store.removeAll { $0.agent == .claudeDesktop }
            return
        }

        let pid = app.processIdentifier
        let id = String(pid)
        let now = Date()
        if let mtime = bridgeStateModifiedAt() {
            if mtime > lastBridgeMTime {
                lastActivityAt = now
                lastBridgeMTime = mtime
            }
        }

        let existingURL = AppPaths.statusDirectory.appendingPathComponent("claude-desktop__\(id).json", isDirectory: false)
        let existing = try? AtomicJSONWriter.read(SessionStatus.self, from: existingURL)

        // Hysteresis: a row already shown as working needs a longer quiet
        // stretch before it drops to idle, so a slow model that pauses briefly
        // between tool calls doesn't flap working↔idle mid-turn.
        let sinceActivity = now.timeIntervalSince(lastActivityAt)
        let threshold = (existing?.state == .working)
            ? DetectionTuning.claudeDesktopWorkingWindow + DetectionTuning.claudeDesktopIdleHysteresis
            : DetectionTuning.claudeDesktopWorkingWindow
        var state: AgentState = sinceActivity < threshold ? .working : .idle
        var event: String? = nil
        // Two AX-based waiting signals: dock badge (preferred) and in-window
        // approval modal (fallback). Both gated by the Preferences toggle.
        if axEnabled {
            if AccessibilityProbe.isTrusted() {
                if let badge = DockBadgeReader.badge(forAppNamed: "Claude") {
                    state = .waiting
                    event = "\(badge) chat\(badge == "1" ? "" : "s") need attention"
                } else if AccessibilityProbe.detectActivity(pid: pid) == .waiting {
                    state = .waiting
                    event = "approval prompt visible"
                }
            } else {
                // Desktop "waiting" detection is enabled but macOS hasn't granted
                // Accessibility — silently impossible before, now visible.
                AKLog.claudeDesktop.notice("AX attention enabled but Accessibility not trusted; cannot read waiting state")
            }
        }

        if let existing,
           existing.state == state,
           now.timeIntervalSince(existing.lastHeartbeatAt) < DetectionTuning.claudeDesktopHeartbeat {
            return
        }

        let status = SessionStatus(
            agent: .claudeDesktop,
            sessionId: id,
            displayName: "Claude Desktop",
            projectPath: nil,
            pid: pid,
            state: state,
            lastTransitionAt: existing?.state == state
                ? (existing?.lastTransitionAt ?? now)
                : now,
            lastHeartbeatAt: now,
            lastEvent: event ?? existing?.lastEvent
        )
        let ok = akWrite(status, to: store, logger: AKLog.claudeDesktop, key: "claude-desktop")
        DetectionDiagnostics.shared.recordScan("claude-desktop", discovered: 1, written: ok ? 1 : 0, errors: ok ? 0 : 1)
    }

    private func bridgeStateModifiedAt() -> Date? {
        try? AppPaths.claudeDesktopBridgeState
            .resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate
    }
}
