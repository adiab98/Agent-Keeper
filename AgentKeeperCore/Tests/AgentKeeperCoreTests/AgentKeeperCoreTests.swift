import XCTest
@testable import AgentKeeperCore

final class AgentKeeperCoreTests: XCTestCase {
    func testSessionStatusRoundTrip() throws {
        // Use millisecond-aligned dates: the on-disk format is
        // millisecondsSince1970, so a raw `Date()` would lose sub-ms precision
        // and fail the equality check for reasons unrelated to encoding.
        let fixed = Date(timeIntervalSince1970: 1_779_000_000)
        let s = SessionStatus(
            agent: .claudeCode,
            sessionId: "abc",
            displayName: "demo",
            projectPath: "/tmp",
            pid: 1234,
            state: .working,
            lastTransitionAt: fixed,
            lastHeartbeatAt: fixed,
            lastEvent: "hello"
        )
        let data = try AtomicJSONWriter.encoder.encode(s)
        let back = try AtomicJSONWriter.decoder.decode(SessionStatus.self, from: data)
        XCTAssertEqual(back, s)
    }

    // MARK: - Claude Code status mapping (real tokens: busy/idle/shell)

    func testClaudeCodeStateMapping() {
        XCTAssertEqual(ClaudeSessionsWatcher.deriveState(status: "busy"), .working)
        XCTAssertEqual(ClaudeSessionsWatcher.deriveState(status: "BUSY"), .working)
        XCTAssertEqual(ClaudeSessionsWatcher.deriveState(status: "working"), .working)
        XCTAssertEqual(ClaudeSessionsWatcher.deriveState(status: "active"), .working)
        XCTAssertEqual(ClaudeSessionsWatcher.deriveState(status: "idle"), .idle)
        XCTAssertEqual(ClaudeSessionsWatcher.deriveState(status: "shell"), .idle)
        XCTAssertEqual(ClaudeSessionsWatcher.deriveState(status: nil), .idle)
        XCTAssertEqual(ClaudeSessionsWatcher.deriveState(status: ""), .idle)
    }

    // MARK: - Codex CLI inference + timestamp parsing

    func testCodexCLIInferState() {
        let now = Date()
        XCTAssertEqual(CodexCLIProducer.inferState(updatedAt: now, now: now), .working)
        XCTAssertEqual(CodexCLIProducer.inferState(updatedAt: now.addingTimeInterval(-2), now: now), .working)
        XCTAssertEqual(CodexCLIProducer.inferState(updatedAt: now.addingTimeInterval(-60), now: now), .idle)
    }

    func testCodexCLITimestampParsing() {
        XCTAssertNotNil(CodexCLIProducer.parseTimestamp("2026-05-28T08:03:19.177508Z"))
        XCTAssertNotNil(CodexCLIProducer.parseTimestamp("2026-05-28T08:03:19Z"))
        XCTAssertNil(CodexCLIProducer.parseTimestamp("not a date"))
    }

    // MARK: - Cowork last-event → state

    func testCoworkStateMapping() {
        XCTAssertEqual(ClaudeCoworkProducer.deriveState(lastEventType: "result"), .idle)
        XCTAssertEqual(ClaudeCoworkProducer.deriveState(lastEventType: ""), .idle)
        XCTAssertEqual(ClaudeCoworkProducer.deriveState(lastEventType: "tool_use"), .working)
        XCTAssertEqual(ClaudeCoworkProducer.deriveState(lastEventType: "assistant"), .working)
    }

    func testCoworkReadLastEventType() throws {
        let url = try writeTemp("audit.jsonl", """
        {"type":"text","seq":1}
        {"type":"tool_use","seq":2}
        {"type":"result","seq":3}
        """)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(ClaudeCoworkProducer.readLastEventType(of: url), "result")
    }

    func testCoworkReadLastEventTypeIgnoresTrailingPartialLine() throws {
        // Mid-write: a complete `result` line followed by a partial line with
        // no newline terminator. We should still read the last *parseable* line.
        let url = try writeTemp("audit2.jsonl", "{\"type\":\"result\"}\n{\"type\":\"par")
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(ClaudeCoworkProducer.readLastEventType(of: url), "result")
    }

    // MARK: - Codex Desktop task ladder

    func testCodexDesktopDeriveState() {
        XCTAssertEqual(CodexDesktopProducer.deriveState(lastTask: "started", mtimeAge: 999), .working)
        XCTAssertEqual(CodexDesktopProducer.deriveState(lastTask: "complete", mtimeAge: 0), .idle)
        // No marker found: fall back to mtime freshness.
        XCTAssertEqual(CodexDesktopProducer.deriveState(lastTask: nil, mtimeAge: 1), .working)
        XCTAssertEqual(CodexDesktopProducer.deriveState(lastTask: nil, mtimeAge: 60), .idle)
    }

    func testCodexDesktopLastTaskStateStarted() throws {
        let url = try writeTemp("rollout-1.jsonl", """
        {"type":"session_meta","payload":{"id":"x","originator":"Codex Desktop"}}
        {"type":"event_msg","payload":{"type":"task_started"}}
        {"type":"event_msg","payload":{"type":"agent_message_delta"}}
        """)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(CodexDesktopProducer.lastTaskState(of: url), "started")
    }

    func testCodexDesktopLastTaskStateComplete() throws {
        let url = try writeTemp("rollout-2.jsonl", """
        {"type":"event_msg","payload":{"type":"task_started"}}
        {"type":"event_msg","payload":{"type":"task_complete"}}
        """)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(CodexDesktopProducer.lastTaskState(of: url), "complete")
    }

    func testCodexDesktopTaskStateCacheSkipsUnchangedFiles() {
        var cache = CodexDesktopProducer.TaskStateCache()
        let url = URL(fileURLWithPath: "/tmp/rollout.jsonl")
        let mtime = Date(timeIntervalSince1970: 1_779_000_000)
        var reads = 0

        let first = cache.state(for: url, size: 10, mtime: mtime) { _ in
            reads += 1
            return "started"
        }
        let second = cache.state(for: url, size: 10, mtime: mtime) { _ in
            reads += 1
            return "complete"
        }

        XCTAssertEqual(first, "started")
        XCTAssertEqual(second, "started")
        XCTAssertEqual(reads, 1)
    }

    func testCodexDesktopTaskStateCacheRescansChangedFiles() {
        var cache = CodexDesktopProducer.TaskStateCache()
        let url = URL(fileURLWithPath: "/tmp/rollout.jsonl")
        let mtime = Date(timeIntervalSince1970: 1_779_000_000)
        var reads = 0

        _ = cache.state(for: url, size: 10, mtime: mtime) { _ in
            reads += 1
            return "started"
        }
        let changed = cache.state(for: url, size: 11, mtime: mtime) { _ in
            reads += 1
            return "complete"
        }

        XCTAssertEqual(changed, "complete")
        XCTAssertEqual(reads, 2)
    }

    // MARK: - Dock-badge attention attribution

    func testDockBadgeSkipsWorkingSession() {
        // The reported bug: the most-recently-active chat is WORKING; an older
        // chat is idle. An app-wide badge must attach to the idle one, never
        // the actively-working one.
        let t = Date(timeIntervalSince1970: 1_779_000_000)
        XCTAssertEqual(
            DockBadgeAttribution.target([(.idle, t), (.working, t.addingTimeInterval(10))]),
            0
        )
    }

    func testDockBadgePicksMostRecentIdle() {
        let t = Date(timeIntervalSince1970: 1_779_000_000)
        XCTAssertEqual(
            DockBadgeAttribution.target([
                (.idle, t),
                (.idle, t.addingTimeInterval(20)),
                (.working, t.addingTimeInterval(30)),
            ]),
            1
        )
    }

    func testDockBadgeNilWhenAllWorking() {
        // Nothing is awaiting the user — flag nothing rather than a working chat.
        let t = Date(timeIntervalSince1970: 1_779_000_000)
        XCTAssertNil(
            DockBadgeAttribution.target([(.working, t), (.working, t.addingTimeInterval(5))])
        )
    }

    func testDockBadgeNilWhenEmpty() {
        XCTAssertNil(DockBadgeAttribution.target([]))
    }

    // MARK: - Accessibility approval classifier

    func testClassifySingleStrongNeedle() {
        // The previously-missed case: a one-positive-button Allow/Deny dialog.
        XCTAssertEqual(AccessibilityProbe.classify(buttonTitles: ["Allow", "Deny"]), .waiting)
        XCTAssertEqual(AccessibilityProbe.classify(buttonTitles: ["Approve", "Reject"]), .waiting)
        XCTAssertEqual(AccessibilityProbe.classify(buttonTitles: ["Always allow"]), .waiting)
    }

    func testClassifyTwoWeakNeedles() {
        XCTAssertEqual(AccessibilityProbe.classify(buttonTitles: ["Run", "Continue"]), .waiting)
    }

    func testClassifyNegatives() {
        XCTAssertEqual(AccessibilityProbe.classify(buttonTitles: ["Cancel", "Deny"]), .none)
        XCTAssertEqual(AccessibilityProbe.classify(buttonTitles: ["Continue"]), .none) // single weak
        XCTAssertEqual(AccessibilityProbe.classify(buttonTitles: []), .none)
    }

    // MARK: - GraceReaper

    func testGraceReaperHoldsThenReaps() {
        let r = GraceReaper(gracePeriod: 6)
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        // b disappears at t0 — held, not reaped yet.
        XCTAssertEqual(r.tick(previousIds: ["a", "b"], liveIds: ["a"], now: t0), [])
        // 7s later, still gone → reaped.
        XCTAssertEqual(r.tick(previousIds: ["a"], liveIds: ["a"], now: t0.addingTimeInterval(7)), ["b"])
    }

    func testGraceReaperReappearanceCancelsReap() {
        let r = GraceReaper(gracePeriod: 6)
        let t0 = Date(timeIntervalSince1970: 2_000_000)
        XCTAssertEqual(r.tick(previousIds: ["a", "b"], liveIds: ["a"], now: t0), [])
        // b comes back within grace → its absence record is cleared.
        XCTAssertEqual(r.tick(previousIds: ["a"], liveIds: ["a", "b"], now: t0.addingTimeInterval(3)), [])
        XCTAssertEqual(r.tick(previousIds: ["a", "b"], liveIds: ["a", "b"], now: t0.addingTimeInterval(20)), [])
    }

    // MARK: - ProcessTree guards

    func testProcessTreeGuards() {
        XCTAssertFalse(ProcessTree.isDescendant(-1, of: 5))
        XCTAssertFalse(ProcessTree.isDescendant(5, of: 0))
        XCTAssertTrue(ProcessTree.isDescendant(42, of: 42))
    }

    // MARK: - Codex wrapper forward-target resolution (Phase 1 regression)

    func testWrapperFreshInstallNoPrior() {
        XCTAssertEqual(
            CodexWrapper.resolveForwardTarget(wrapperPath: "/w", configArray: [], existingWrapperOriginal: []),
            []
        )
    }

    func testWrapperFreshInstallWithPriorProgram() {
        XCTAssertEqual(
            CodexWrapper.resolveForwardTarget(wrapperPath: "/w", configArray: ["/usr/bin/foo"], existingWrapperOriginal: []),
            ["/usr/bin/foo"]
        )
    }

    func testWrapperReinstallIsIdempotent() {
        // Config already points at the wrapper; the real prior program lives in
        // the existing wrapper's ORIGINAL and must be preserved.
        XCTAssertEqual(
            CodexWrapper.resolveForwardTarget(wrapperPath: "/w", configArray: ["/w"], existingWrapperOriginal: ["/usr/bin/foo"]),
            ["/usr/bin/foo"]
        )
    }

    func testWrapperRepairsSelfReference() {
        // THE bug: a previously-corrupted wrapper forwards to itself. Re-install
        // must strip the self-reference and produce a clean (empty) target.
        XCTAssertEqual(
            CodexWrapper.resolveForwardTarget(wrapperPath: "/w", configArray: ["/w"], existingWrapperOriginal: ["/w"]),
            []
        )
    }

    func testWrapperSamePathNormalizes() {
        XCTAssertTrue(CodexWrapper.samePath("/a/../w", "/w"))
        XCTAssertFalse(CodexWrapper.samePath("/w", "/x"))
    }

    // MARK: - Codex notify TOML parsing

    /// The shape SkyComputerUseClient writes when it wraps our wrapper: the
    /// last element is a JSON string containing `[`, `]`, `\"` and `\\`.
    private let skyNotifyLine =
        #"notify = ["/Apps/Sky", "turn-ended", "--previous-notify", "[\"\\/Users\\/me\\/wrap.sh\"]"]"#

    func testNotifyArraySimple() {
        XCTAssertEqual(CodexWrapper.extractNotifyArray(from: "notify = [\"/w\"]\n"), ["/w"])
    }

    func testNotifyLineRangeSpansQuotedBrackets() {
        // Regression: a `]` inside a quoted element must not terminate the
        // array early — that left the real tail (`"]`) orphaned on its own
        // line and corrupted config.toml so Codex refused to start.
        let text = "model = \"gpt-5.5\"\n\(skyNotifyLine)\n\n[features]\njs_repl = false\n"
        guard let r = CodexWrapper.notifyLineRange(in: text) else {
            return XCTFail("notify line not found")
        }
        let replaced = text.replacingCharacters(in: r, with: "notify = [\"/w\"]\n")
        XCTAssertEqual(replaced, "model = \"gpt-5.5\"\nnotify = [\"/w\"]\n\n[features]\njs_repl = false\n")
    }

    func testNotifyArrayElementsMayContainBrackets() {
        XCTAssertEqual(
            CodexWrapper.extractNotifyArray(from: skyNotifyLine),
            ["/Apps/Sky", "turn-ended", "--previous-notify", #"["\/Users\/me\/wrap.sh"]"#]
        )
    }

    // MARK: - helpers

    private func writeTemp(_ name: String, _ contents: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("akcore-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name, isDirectory: false)
        try contents.data(using: .utf8)!.write(to: url)
        return url
    }
}
