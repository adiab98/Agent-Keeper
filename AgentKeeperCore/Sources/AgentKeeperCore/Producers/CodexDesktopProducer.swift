import Foundation
import AppKit

/// Tracks Codex Desktop conversations as per-chat rows.
///
/// Codex (CLI and Desktop) writes one rollout-*.jsonl file per conversation
/// under `~/.codex/sessions/<YYYY>/<MM>/<DD>/`. The first line is a
/// `session_meta` event carrying `id`, `cwd`, and `originator` (which tells
/// us whether it's a Desktop or CLI conversation). Subsequent lines include
/// `event_msg/task_started` and `event_msg/task_complete` — the same
/// authoritative turn-state signal we used in the previous single-row
/// implementation.
///
/// Friendly chat titles come from `~/.codex/session_index.jsonl`, keyed by
/// the same session id.
///
/// Dock badge → "needs attention" still applies app-wide; we attach it to the
/// most-recently-active Desktop conversation (best proxy for "this chat
/// needs you").
public final class CodexDesktopProducer {
    private let bundleId = "com.openai.codex"
    private let store: StatusStore
    private let queue = DispatchQueue(label: "agentkeeper.codex-desktop")
    private var timer: DispatchSourceTimer?
    private let reaper = GraceReaper()
    private var taskStateCache = TaskStateCache()

    private var axEnabled: Bool {
        UserDefaults.standard.bool(forKey: "agentkeeper.ax.desktopAttention")
    }

    public init(store: StatusStore) {
        self.store = store
    }

    public func start() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1.0, repeating: .seconds(DetectionTuning.codexDesktopPoll))
        t.setEventHandler { [weak self] in self?.scan() }
        t.resume()
        timer = t
    }

    public func stop() { timer?.cancel(); timer = nil }
    deinit { stop() }

    private struct Discovered {
        let sessionId: String           // 8-char prefix of the session UUID
        let fullId: String              // full UUID for index lookup
        let displayName: String
        let cwd: String?
        let auditURL: URL
        let auditMTime: Date
        let derivedState: AgentState
    }

    struct TaskStateCache {
        private struct Entry {
            let size: UInt64
            let mtime: Date
            let state: String?
        }

        private var entries: [String: Entry] = [:]

        mutating func state(
            for url: URL,
            size: UInt64,
            mtime: Date,
            loader: (URL) -> String?
        ) -> String? {
            let key = url.standardizedFileURL.path
            if let cached = entries[key],
               cached.size == size,
               cached.mtime == mtime {
                return cached.state
            }
            let loaded = loader(url)
            entries[key] = Entry(size: size, mtime: mtime, state: loaded)
            return loaded
        }

        mutating func keepOnly(_ livePaths: Set<String>) {
            entries = entries.filter { livePaths.contains($0.key) }
        }
    }

    private func scan() {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
        guard let app = apps.first else {
            store.removeAll { $0.agent == .codexDesktop }
            return
        }

        let now = Date()
        let activeWindow = DetectionTuning.codexDesktopActiveWindow
        let titleMap = loadThreadNames()
        let discovered = enumerateRollouts(activeWindow: activeWindow, now: now, titleMap: titleMap)

        var liveIds: Set<String> = []
        var written = 0

        for d in discovered {
            liveIds.insert(d.sessionId)
            if writeStatus(d, pid: app.processIdentifier, now: now) { written += 1 }
        }

        // Dock-badge attention → most-recently-active session that is NOT
        // working. A working chat is mid-turn and never "needs attention", so
        // the app-wide badge must not override it (see DockBadgeAttribution).
        if axEnabled {
            if AccessibilityProbe.isTrusted() {
                if let badge = DockBadgeReader.badge(forAppNamed: "Codex"),
                   let idx = DockBadgeAttribution.target(discovered.map { ($0.derivedState, $0.auditMTime) }) {
                    let recent = discovered[idx]
                    let url = AppPaths.statusDirectory.appendingPathComponent("codex-desktop__\(recent.sessionId).json", isDirectory: false)
                    if var s = try? AtomicJSONWriter.read(SessionStatus.self, from: url) {
                        s.state = .waiting
                        s.lastTransitionAt = now
                        s.lastHeartbeatAt = now
                        s.lastEvent = "\(badge) chat\(badge == "1" ? "" : "s") need attention"
                        if akWrite(s, to: store, logger: AKLog.codexDesktop, key: "codex-desktop") { written += 1 }
                    }
                }
            } else {
                AKLog.codexDesktop.notice("AX attention enabled but Accessibility not trusted; cannot read dock badge")
            }
        }

        DetectionDiagnostics.shared.recordScan("codex-desktop", discovered: discovered.count, written: written, errors: 0)

        // Reap with grace.
        let known: Set<String> = Set(store.readAll()
            .filter { $0.agent == .codexDesktop }
            .map(\.sessionId))
        for id in reaper.tick(previousIds: known, liveIds: liveIds) {
            store.remove("codex-desktop__\(id)")
        }
    }

    // MARK: - Enumerate

    private func enumerateRollouts(activeWindow: TimeInterval, now: Date, titleMap: [String: String]) -> [Discovered] {
        let root = AppPaths.codexSessionsDir
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey], options: [.skipsHiddenFiles]) else {
            return []
        }
        var results: [Discovered] = []
        for case let url as URL in enumerator {
            let name = url.lastPathComponent
            guard name.hasPrefix("rollout-"), name.hasSuffix(".jsonl") else { continue }
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let mtime = values?.contentModificationDate ?? .distantPast
            let size = UInt64(values?.fileSize ?? 0)
            guard now.timeIntervalSince(mtime) < activeWindow else { continue }

            guard let meta = readSessionMeta(of: url) else { continue }
            // Only Codex Desktop sessions belong in this producer.
            guard meta.originator == "Codex Desktop" else { continue }
            guard let id = meta.id, !id.isEmpty else { continue }

            // Working/idle ladder:
            //  1. If we see `task_complete` more recent than `task_started`
            //     in the tail → idle (turn ended).
            //  2. If we see `task_started` more recent than `task_complete`
            //     → working.
            //  3. If neither is found in the scanned tail BUT the file mtime
            //     is fresh (within the last 5s), the file is mid-turn with
            //     so much token traffic that the task markers have fallen
            //     past our scan window — treat as working.
            //  4. Otherwise → idle.
            let lastTask = taskStateCache.state(for: url, size: size, mtime: mtime) {
                Self.lastTaskState(of: $0)
            }
            let derived = Self.deriveState(lastTask: lastTask, mtimeAge: now.timeIntervalSince(mtime))
            let display = friendlyName(id: id, cwd: meta.cwd, titleMap: titleMap)
            let shortId = String(id.prefix(8))

            results.append(Discovered(
                sessionId: shortId,
                fullId: id,
                displayName: display,
                cwd: meta.cwd,
                auditURL: url,
                auditMTime: mtime,
                derivedState: derived
            ))
        }
        taskStateCache.keepOnly(Set(results.map { $0.auditURL.standardizedFileURL.path }))
        return results
    }

    // MARK: - File parsing

    private struct SessionMeta {
        let id: String?
        let cwd: String?
        let originator: String?
    }

    private func readSessionMeta(of url: URL) -> SessionMeta? {
        // First line of every rollout file is session_meta. Read enough to
        // cover even verbose session_meta payloads (the line includes the
        // user's full env / git context and can exceed 16KB).
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        guard let data = try? fh.read(upToCount: 131072),
              let text = String(data: data, encoding: .utf8) else { return nil }
        // Only consider the FIRST complete line (anything before the first \n).
        // Split-on-newline may yield a partial last element if we hit our
        // read cap mid-second-line, but the first line is always complete
        // for any reasonable session_meta.
        guard let firstNewline = text.firstIndex(of: "\n") else { return nil }
        let firstLine = text[text.startIndex..<firstNewline]
        guard let lineData = firstLine.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
            return nil
        }
        guard (obj["type"] as? String) == "session_meta",
              let payload = obj["payload"] as? [String: Any] else { return nil }
        return SessionMeta(
            id: payload["id"] as? String,
            cwd: payload["cwd"] as? String,
            originator: payload["originator"] as? String
        )
    }

    /// Walk backwards through the file in 256KB chunks looking for the most
    /// recent `event_msg/task_started` or `event_msg/task_complete`. Caps at
    /// 4MB total to keep scan bounded — turns longer than that fall back to
    /// the file-growth heuristic in the caller. Returns "started",
    /// "complete", or nil.
    /// Maps the most-recent task marker (or a fresh mtime fallback) to a state.
    /// Extracted so the test suite can pin the working/idle ladder.
    static func deriveState(lastTask: String?, mtimeAge: TimeInterval) -> AgentState {
        switch lastTask {
        case "started": return .working
        case "complete": return .idle
        default: return mtimeAge < DetectionTuning.rolloutMTimeWorkingWindow ? .working : .idle
        }
    }

    static func lastTaskState(of url: URL) -> String? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        let size: UInt64 = (try? fh.seekToEnd()) ?? 0
        guard size > 0 else { return nil }
        let chunkSize = DetectionTuning.rolloutScanChunk
        let maxBytes = DetectionTuning.rolloutScanCap

        var scanned: UInt64 = 0
        var carryover = ""
        while scanned < min(maxBytes, size) {
            let bytesToRead = min(chunkSize, size - scanned)
            scanned += bytesToRead
            let offset = size - scanned
            try? fh.seek(toOffset: offset)
            guard let data = try? fh.read(upToCount: Int(bytesToRead)),
                  let text = String(data: data, encoding: .utf8) else { break }

            // Combine with carryover from previous (later in file) iteration,
            // then split. The first piece may be a partial line (start of
            // some line whose end lives in the previous chunk) — discard it
            // by saving it as new carryover unless we're at the very start.
            let combined = text + carryover
            let pieces = combined.split(separator: "\n", omittingEmptySubsequences: false)
            // Save the FIRST piece (potentially partial) for the next iteration.
            carryover = scanned < size ? String(pieces.first ?? "") : ""
            // Walk the rest from the back.
            let parsable = pieces.dropFirst()
            for line in parsable.reversed() {
                guard !line.isEmpty else { continue }
                guard line.contains("task_started") || line.contains("task_complete") else { continue }
                guard let lineData = line.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                      (obj["type"] as? String) == "event_msg",
                      let payload = obj["payload"] as? [String: Any],
                      let pt = payload["type"] as? String else { continue }
                if pt == "task_started" { return "started" }
                if pt == "task_complete" { return "complete" }
            }
        }
        // Scanned the whole cap without finding a marker on a large file: the
        // turn markers fell past our window, so the caller's mtime fallback
        // decides. Worth noting — it means the state for this huge rollout is a
        // guess, not an event read.
        if size > maxBytes {
            AKLog.codexDesktop.notice("rollout \(url.lastPathComponent, privacy: .public) exceeds \(maxBytes) byte scan cap; falling back to mtime heuristic")
        }
        return nil
    }

    /// Loads [session-id → thread_name] from `~/.codex/session_index.jsonl`.
    private func loadThreadNames() -> [String: String] {
        guard let data = try? Data(contentsOf: AppPaths.codexSessionIndex),
              let text = String(data: data, encoding: .utf8) else { return [:] }
        var map: [String: String] = [:]
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let lineData = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let id = obj["id"] as? String,
                  let name = obj["thread_name"] as? String, !name.isEmpty else { continue }
            map[id] = name
        }
        return map
    }

    private func friendlyName(id: String, cwd: String?, titleMap: [String: String]) -> String {
        if let title = titleMap[id], !title.isEmpty {
            return "Codex · \(title.prefix(50))"
        }
        if let cwd, !cwd.isEmpty {
            return "Codex · \(URL(fileURLWithPath: cwd).lastPathComponent)"
        }
        return "Codex · \(id.prefix(8))"
    }

    // MARK: - Write

    @discardableResult
    private func writeStatus(_ d: Discovered, pid: Int32, now: Date) -> Bool {
        let existingURL = AppPaths.statusDirectory.appendingPathComponent("codex-desktop__\(d.sessionId).json", isDirectory: false)
        let existing = try? AtomicJSONWriter.read(SessionStatus.self, from: existingURL)

        // Preserve `.waiting` until the underlying state goes working again.
        var nextState = d.derivedState
        if let existing, existing.state == .waiting, d.derivedState != .working {
            nextState = .waiting
        }

        if let existing,
           existing.state == nextState,
           existing.displayName == d.displayName,
           now.timeIntervalSince(existing.lastHeartbeatAt) < DetectionTuning.codexDesktopHeartbeat {
            return false
        }

        let status = SessionStatus(
            agent: .codexDesktop,
            sessionId: d.sessionId,
            displayName: d.displayName,
            projectPath: d.cwd,
            pid: pid,
            state: nextState,
            lastTransitionAt: existing?.state == nextState ? (existing?.lastTransitionAt ?? now) : now,
            lastHeartbeatAt: now,
            // lastEvent here is only ever the dock-badge "needs attention" note.
            // Drop it once the chat is no longer waiting so a working/idle row
            // doesn't keep a stale "N chats need attention" subtitle.
            lastEvent: nextState == .waiting ? existing?.lastEvent : nil
        )
        return akWrite(status, to: store, logger: AKLog.codexDesktop, key: "codex-desktop")
    }
}
