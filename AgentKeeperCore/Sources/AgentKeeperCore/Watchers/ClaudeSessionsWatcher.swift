import Foundation

/// Watches `~/.claude/sessions/<pid>.json` files.
///
/// Each file is maintained by Claude Code itself and contains
/// `{pid, sessionId, cwd, name, status: "busy"|"idle", updatedAt, ...}`.
/// We map that into our canonical SessionStatus and write it to the
/// AgentKeeper status directory. The `Notification` hook (handled by the
/// agentkeeper-hook helper) is what flips state to `waiting`; this watcher
/// never overrides a `waiting` state until the underlying session goes busy
/// again.
public final class ClaudeSessionsWatcher {
    private let store: StatusStore
    private var source: DispatchSourceFileSystemObject?
    private var fd: CInt = -1
    private var pollTimer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "agentkeeper.claude-sessions")
    private let reaper = GraceReaper()

    public init(store: StatusStore) {
        self.store = store
    }

    public func start() {
        let dir = AppPaths.claudeSessionsDir
        AppPaths.ensureDirectory(dir)
        fd = open(dir.path, O_EVTONLY)
        if fd >= 0 {
            let s = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd,
                eventMask: [.write, .extend, .attrib, .rename, .delete],
                queue: queue
            )
            s.setEventHandler { [weak self] in self?.scan() }
            s.setCancelHandler { [weak self] in
                guard let self else { return }
                if self.fd >= 0 {
                    close(self.fd)
                    self.fd = -1
                }
            }
            s.resume()
            source = s
        }

        // Lightweight 1Hz reconciliation to catch in-place file edits that
        // FSEvents on the parent dir might not surface.
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 0.5, repeating: .seconds(DetectionTuning.claudeSessionsPoll))
        t.setEventHandler { [weak self] in self?.scan() }
        t.resume()
        pollTimer = t
    }

    public func stop() {
        source?.cancel()
        source = nil
        pollTimer?.cancel()
        pollTimer = nil
    }

    deinit { stop() }

    // MARK: - Scan

    /// Maps Claude Code's `status` token to our state. Claude Code emits
    /// `busy` / `idle` / `shell` (and occasionally omits it). Extracted so the
    /// test suite pins this mapping against drift in Claude Code's schema.
    static func deriveState(status: String?) -> AgentState {
        switch (status ?? "").lowercased() {
        case "busy", "working", "active": return .working
        default: return .idle
        }
    }

    private struct ClaudeSessionFile: Decodable {
        let pid: Int32?
        let sessionId: String?
        let cwd: String?
        let name: String?
        let status: String?
    }

    private func scan() {
        let fm = FileManager.default
        let dir = AppPaths.claudeSessionsDir
        let entries: [URL]
        do {
            entries = try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        } catch {
            AKLog.claudeCode.error("Failed to list \(dir.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            DetectionDiagnostics.shared.recordError("claude-code", "list sessions dir: \(error.localizedDescription)")
            return
        }

        var liveSessionIds: Set<String> = []
        var discovered = 0, written = 0, errored = 0

        for url in entries where url.pathExtension == "json" && !url.lastPathComponent.hasPrefix(".") {
            guard let data = try? Data(contentsOf: url),
                  let f = try? JSONDecoder().decode(ClaudeSessionFile.self, from: data),
                  let sid = f.sessionId, !sid.isEmpty
            else {
                // A file that exists but won't decode is worth knowing about —
                // it usually means Claude Code changed the session-file schema.
                if (try? Data(contentsOf: url)) != nil {
                    AKLog.claudeCode.error("Unparseable session file \(url.lastPathComponent, privacy: .public)")
                    DetectionDiagnostics.shared.recordError("claude-code", "unparseable \(url.lastPathComponent)")
                    errored += 1
                }
                continue
            }
            discovered += 1

            liveSessionIds.insert(sid)

            let derivedState = Self.deriveState(status: f.status)

            // If an existing status file says `waiting`, preserve it until
            // the session goes busy again.
            let id = "claude-code__\(sid)"
            let existingURL = AppPaths.statusDirectory.appendingPathComponent("\(id).json", isDirectory: false)
            var preservedWaiting = false
            if let existing = try? AtomicJSONWriter.read(SessionStatus.self, from: existingURL),
               existing.state == .waiting,
               derivedState != .working {
                preservedWaiting = true
            }

            let cwd = f.cwd
            let displayName = f.name?.nonEmpty
                ?? cwd.map { URL(fileURLWithPath: $0).lastPathComponent }
                ?? "Claude Code"
            let nextState: AgentState = preservedWaiting ? .waiting : derivedState
            let now = Date()

            let existing = try? AtomicJSONWriter.read(SessionStatus.self, from: existingURL)
            let stateChanged = existing?.state != nextState
            let displayChanged = existing?.displayName != displayName
            let pidChanged = existing?.pid != f.pid
            let pathChanged = existing?.projectPath != cwd
            let heartbeatAge = existing.map { now.timeIntervalSince($0.lastHeartbeatAt) } ?? .infinity
            // Skip if nothing meaningful changed and we already refreshed recently.
            if !stateChanged && !displayChanged && !pidChanged && !pathChanged
                && heartbeatAge < DetectionTuning.claudeSessionsHeartbeat {
                continue
            }

            let status = SessionStatus(
                agent: .claudeCode,
                sessionId: sid,
                displayName: displayName,
                projectPath: cwd,
                pid: f.pid,
                state: nextState,
                lastTransitionAt: stateChanged ? now : (existing?.lastTransitionAt ?? now),
                lastHeartbeatAt: now,
                lastEvent: preservedWaiting ? (existing?.lastEvent ?? "waiting on input") : existing?.lastEvent
            )
            if akWrite(status, to: store, logger: AKLog.claudeCode, key: "claude-code") {
                written += 1
            } else {
                errored += 1
            }
        }

        DetectionDiagnostics.shared.recordScan("claude-code", discovered: discovered, written: written, errors: errored)

        // Reap status files for sessions whose source files have disappeared —
        // but only after a brief grace so transient producer hiccups don't
        // make rows blink in/out of the UI.
        let known: Set<String> = Set(store.readAll()
            .filter { $0.agent == .claudeCode }
            .map(\.sessionId))
        for id in reaper.tick(previousIds: known, liveIds: liveSessionIds) {
            store.remove("claude-code__\(id)")
        }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
