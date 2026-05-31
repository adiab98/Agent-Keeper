import Foundation

/// Seeds and refreshes rows for the Codex CLI based on `~/.codex/session_index.jsonl`.
///
/// The notify wrapper (when installed) is the authoritative source for state
/// transitions. This producer only ever writes when the existing row is older
/// than ~10s and the session has been active recently, so notify-driven state
/// (especially `waiting`) is never clobbered.
public final class CodexCLIProducer {
    private let store: StatusStore
    private let queue = DispatchQueue(label: "agentkeeper.codex-cli")
    private var timer: DispatchSourceTimer?
    private let reaper = GraceReaper()

    public init(store: StatusStore) {
        self.store = store
    }

    public func start() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1.0, repeating: .seconds(DetectionTuning.codexCLIPoll))
        t.setEventHandler { [weak self] in self?.scan() }
        t.resume()
        timer = t
    }

    public func stop() {
        timer?.cancel(); timer = nil
    }

    deinit { stop() }

    private struct IndexLine: Decodable {
        let id: String?
        let thread_name: String?
        let updated_at: String?
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private func scan() {
        let url = AppPaths.codexSessionIndex
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            // A missing index just means Codex CLI hasn't been used yet — not
            // an error worth surfacing. Anything else (permissions, IO) is.
            if FileManager.default.fileExists(atPath: url.path) {
                AKLog.codexCLI.error("read \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
                DetectionDiagnostics.shared.recordError("codex-cli", "read index: \(error.localizedDescription)")
            }
            DetectionDiagnostics.shared.recordScan("codex-cli", discovered: 0, written: 0, errors: 0)
            return
        }
        guard let text = String(data: data, encoding: .utf8) else {
            AKLog.codexCLI.error("session_index.jsonl is not valid UTF-8")
            DetectionDiagnostics.shared.recordError("codex-cli", "index not UTF-8")
            return
        }

        let now = Date()
        let activeWindow = DetectionTuning.codexCLIActiveWindow

        var latestByID: [String: IndexLine] = [:]
        for line in text.split(separator: "\n") {
            guard let lineData = line.data(using: .utf8),
                  let entry = try? JSONDecoder().decode(IndexLine.self, from: lineData),
                  let id = entry.id else { continue }
            latestByID[id] = entry
        }

        var active: Set<String> = []
        var discovered = 0, written = 0
        for (id, entry) in latestByID {
            guard let updatedStr = entry.updated_at,
                  let updatedDate = Self.parseTimestamp(updatedStr) else { continue }
            guard now.timeIntervalSince(updatedDate) < activeWindow else { continue }
            active.insert(id)
            discovered += 1

            let existingURL = AppPaths.statusDirectory.appendingPathComponent("codex-cli__\(id).json", isDirectory: false)
            let existing = try? AtomicJSONWriter.read(SessionStatus.self, from: existingURL)
            // The notify wrapper is the authoritative source for state. The
            // session_index.jsonl only updates per-thread (not continuously
            // through a turn), so we must NOT downgrade a hook-set `working`
            // or `waiting` to `idle` from a stale index timestamp — that was
            // the old bug that flipped long turns to idle mid-work. We only
            // SEED a row the hook hasn't created yet, and refresh heartbeats.
            if let e = existing {
                if e.state == .waiting || e.state == .working { continue }
                let heartbeatAge = now.timeIntervalSince(e.lastHeartbeatAt)
                if heartbeatAge < DetectionTuning.codexCLIHeartbeat { continue }
            }

            let inferredState = Self.inferState(updatedAt: updatedDate, now: now)
            let displayName = entry.thread_name?.nonEmpty ?? "Codex session"
            let status = SessionStatus(
                agent: .codexCLI,
                sessionId: id,
                displayName: displayName,
                projectPath: nil,
                pid: nil,
                state: inferredState,
                lastTransitionAt: existing?.state == inferredState
                    ? (existing?.lastTransitionAt ?? now)
                    : now,
                lastHeartbeatAt: now,
                lastEvent: existing?.lastEvent
            )
            if akWrite(status, to: store, logger: AKLog.codexCLI, key: "codex-cli") { written += 1 }
        }

        DetectionDiagnostics.shared.recordScan("codex-cli", discovered: discovered, written: written, errors: 0)

        // GC with grace: drop codex-cli rows whose entries fell out of the
        // active window, but only after they've been missing long enough
        // that we're sure it's not a transient.
        let known: Set<String> = Set(store.readAll()
            .filter { $0.agent == .codexCLI }
            .map(\.sessionId))
        for id in reaper.tick(previousIds: known, liveIds: active) {
            store.remove("codex-cli__\(id)")
        }
    }
}

extension CodexCLIProducer {
    /// Index timestamps only tell us "recently touched". A very fresh entry is
    /// treated as `working`; otherwise the safe default is `idle` (the notify
    /// hook supplies the real `working`/`waiting`).
    static func inferState(updatedAt: Date, now: Date) -> AgentState {
        now.timeIntervalSince(updatedAt) < DetectionTuning.rolloutMTimeWorkingWindow ? .working : .idle
    }

    static func parseTimestamp(_ s: String) -> Date? {
        if let d = isoFormatter.date(from: s) { return d }
        let alt = ISO8601DateFormatter()
        alt.formatOptions = [.withInternetDateTime]
        return alt.date(from: s)
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
