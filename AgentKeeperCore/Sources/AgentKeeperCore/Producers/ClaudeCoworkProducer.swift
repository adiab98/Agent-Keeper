import Foundation
import AppKit

/// Tracks individual Claude Cowork sessions.
///
/// Cowork sessions live inside Claude Desktop and write per-turn events to:
///
/// ```
/// ~/Library/Application Support/Claude/local-agent-mode-sessions/
///   <accountId>/<conversationId>/local_<sessionId>/audit.jsonl
/// ```
///
/// `audit.jsonl` is the authoritative durable signal — it grows in real
/// time as the embedded Claude agent processes a turn. A trailing line of
/// type=`result` marks turn completion. We can't rely on the per-pid
/// session.json file because Cowork recycles claude processes mid-session
/// and that file goes missing between turns.
///
/// Working/idle is derived from audit.jsonl size growth (same pattern we
/// use for Codex's rollout file). Waiting comes from the parent Claude.app
/// dock badge, attached to the most-recently-active session.
public final class ClaudeCoworkProducer {
    private let bundleId = "com.anthropic.claudefordesktop"
    private let store: StatusStore
    private let queue = DispatchQueue(label: "agentkeeper.claude-cowork")
    private var timer: DispatchSourceTimer?

    private let reaper = GraceReaper()

    private var axEnabled: Bool {
        UserDefaults.standard.bool(forKey: "agentkeeper.ax.desktopAttention")
    }

    public init(store: StatusStore) {
        self.store = store
    }

    public func start() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1.0, repeating: .seconds(DetectionTuning.claudeCoworkPoll))
        t.setEventHandler { [weak self] in self?.scan() }
        t.resume()
        timer = t
    }

    public func stop() { timer?.cancel(); timer = nil }
    deinit { stop() }

    /// One discovered Cowork session ready to project into SessionStatus.
    private struct Discovered {
        let sessionId: String
        let displayName: String
        let auditURL: URL
        let auditMTime: Date
        let lastEventType: String
    }

    private func scan() {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
        guard let app = apps.first else {
            store.removeAll { $0.agent == .claudeCowork }
            return
        }

        let now = Date()
        // 60 min active window — long-running tool calls can leave audit.jsonl
        // untouched for many minutes mid-turn; we don't want those to vanish.
        let activeWindow = DetectionTuning.claudeCoworkActiveWindow

        let discovered = enumerate(activeWindow: activeWindow, now: now)
        var liveIds: Set<String> = []
        var written = 0

        for d in discovered {
            liveIds.insert(d.sessionId)
            // Working state = last event in audit.jsonl is anything other than
            // `result`. The agent writes `result` when the turn fully completes.
            // Mid-turn (running tools, awaiting tokens, etc.) any other type
            // means the turn is still open.
            let state: AgentState = Self.deriveState(lastEventType: d.lastEventType)
            if writeStatus(d, pid: app.processIdentifier, now: now, derivedState: state) { written += 1 }
        }

        // Dock-badge waiting → most-recently-active session that is NOT working.
        // A working chat is mid-turn and never "needs attention", so the
        // app-wide badge must not override it (see DockBadgeAttribution).
        if axEnabled {
            if AccessibilityProbe.isTrusted() {
                if let badge = DockBadgeReader.badge(forAppNamed: "Claude"),
                   let idx = DockBadgeAttribution.target(discovered.map { (Self.deriveState(lastEventType: $0.lastEventType), $0.auditMTime) }) {
                    let recent = discovered[idx]
                    let url = AppPaths.statusDirectory.appendingPathComponent("claude-cowork__\(recent.sessionId).json", isDirectory: false)
                    if var s = try? AtomicJSONWriter.read(SessionStatus.self, from: url) {
                        s.state = .waiting
                        s.lastTransitionAt = now
                        s.lastHeartbeatAt = now
                        s.lastEvent = "\(badge) chat\(badge == "1" ? "" : "s") need attention"
                        if akWrite(s, to: store, logger: AKLog.claudeCowork, key: "claude-cowork") { written += 1 }
                    }
                }
            } else {
                AKLog.claudeCowork.notice("AX attention enabled but Accessibility not trusted; cannot read dock badge")
                DetectionDiagnostics.shared.recordError("claude-cowork", "Accessibility permission not granted")
            }
        }

        DetectionDiagnostics.shared.recordScan("claude-cowork", discovered: discovered.count, written: written, errors: 0)

        // Reap with grace: only delete cowork rows once they've been
        // continuously absent from this scan for ≥6s. Keeps rows from
        // blinking when a producer briefly misses a session file mid-write.
        let known: Set<String> = Set(store.readAll()
            .filter { $0.agent == .claudeCowork }
            .map(\.sessionId))
        for id in reaper.tick(previousIds: known, liveIds: liveIds) {
            store.remove("claude-cowork__\(id)")
        }
    }

    private func enumerate(activeWindow: TimeInterval, now: Date) -> [Discovered] {
        let root = AppPaths.claudeDesktopAppSupport.appendingPathComponent("local-agent-mode-sessions", isDirectory: true)
        let fm = FileManager.default
        guard let accountDirs = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else {
            return []
        }
        var results: [Discovered] = []
        for accountDir in accountDirs {
            guard isDirectory(accountDir) else { continue }
            guard let convoDirs = try? fm.contentsOfDirectory(at: accountDir, includingPropertiesForKeys: nil) else { continue }
            for convoDir in convoDirs {
                guard isDirectory(convoDir) else { continue }
                guard let localDirs = try? fm.contentsOfDirectory(at: convoDir, includingPropertiesForKeys: nil) else { continue }
                for localDir in localDirs {
                    let name = localDir.lastPathComponent
                    guard name.hasPrefix("local_"), isDirectory(localDir) else { continue }
                    let audit = localDir.appendingPathComponent("audit.jsonl", isDirectory: false)
                    guard let attrs = try? fm.attributesOfItem(atPath: audit.path),
                          let mtime = attrs[.modificationDate] as? Date else { continue }
                    guard now.timeIntervalSince(mtime) < activeWindow else { continue }

                    let convoMetadata = convoDir.appendingPathComponent("\(name).json", isDirectory: false)
                    let display = friendlyName(localUUID: name, convoUUID: convoDir.lastPathComponent, metadata: convoMetadata)
                    let shortLocal = String(name.dropFirst("local_".count).prefix(8))
                    let shortConvo = String(convoDir.lastPathComponent.prefix(8))
                    let lastType = Self.readLastEventType(of: audit) ?? ""
                    results.append(Discovered(
                        sessionId: "\(shortConvo)-\(shortLocal)",
                        displayName: display,
                        auditURL: audit,
                        auditMTime: mtime,
                        lastEventType: lastType
                    ))
                }
            }
        }
        return results
    }

    /// Try the sibling `local_<uuid>.json` for a chat title; fall back to
    /// derived names from UUIDs.
    private func friendlyName(localUUID: String, convoUUID: String, metadata: URL) -> String {
        if let data = try? Data(contentsOf: metadata),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for key in ["title", "name", "chatTitle", "conversationTitle"] {
                if let s = obj[key] as? String, !s.isEmpty {
                    return "Cowork · \(s.prefix(40))"
                }
            }
        }
        return "Cowork · \(String(convoUUID.prefix(6)))…\(String(localUUID.dropFirst("local_".count).prefix(4)))"
    }

    /// Working = last event in audit.jsonl is anything other than `result`
    /// (the agent writes `result` only when the turn fully completes).
    static func deriveState(lastEventType: String) -> AgentState {
        (lastEventType == "result" || lastEventType.isEmpty) ? .idle : .working
    }

    @discardableResult
    private func writeStatus(_ d: Discovered, pid: Int32, now: Date, derivedState: AgentState) -> Bool {
        let existingURL = AppPaths.statusDirectory.appendingPathComponent("claude-cowork__\(d.sessionId).json", isDirectory: false)
        let existing = try? AtomicJSONWriter.read(SessionStatus.self, from: existingURL)

        // Preserve `.waiting` until the underlying audit shows working again.
        var nextState = derivedState
        if let existing, existing.state == .waiting, derivedState != .working {
            nextState = .waiting
        }

        if let existing,
           existing.state == nextState,
           existing.displayName == d.displayName,
           now.timeIntervalSince(existing.lastHeartbeatAt) < DetectionTuning.coworkHeartbeat {
            return false
        }

        let status = SessionStatus(
            agent: .claudeCowork,
            sessionId: d.sessionId,
            displayName: d.displayName,
            projectPath: nil,
            pid: pid,
            state: nextState,
            lastTransitionAt: existing?.state == nextState ? (existing?.lastTransitionAt ?? now) : now,
            lastHeartbeatAt: now,
            // lastEvent here is only ever the dock-badge "needs attention" note.
            // Drop it once the chat is no longer waiting so a working/idle row
            // doesn't keep a stale "N chats need attention" subtitle.
            lastEvent: nextState == .waiting ? existing?.lastEvent : nil
        )
        return akWrite(status, to: store, logger: AKLog.claudeCowork, key: "claude-cowork")
    }

    private func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    /// Reads the last complete JSON line from an audit.jsonl file by tailing
    /// the last 8KB, then walking backwards to find a parseable line. Returns
    /// the `type` field of the last event. Cheap; no need to load the whole
    /// file.
    static func readLastEventType(of url: URL) -> String? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        let size: UInt64 = (try? fh.seekToEnd()) ?? 0
        guard size > 0 else { return nil }
        let chunk: UInt64 = min(DetectionTuning.auditTailBytes, size)
        try? fh.seek(toOffset: size - chunk)
        guard let data = try? fh.read(upToCount: Int(chunk)),
              let text = String(data: data, encoding: .utf8) else { return nil }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        for line in lines.reversed() {
            guard let lineData = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let type = obj["type"] as? String, !type.isEmpty else { continue }
            return type
        }
        return nil
    }
}
