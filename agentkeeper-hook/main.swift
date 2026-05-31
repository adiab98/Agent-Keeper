import Foundation
import Darwin

// Stays Foundation-light. Must complete in <50ms.
// Called by Claude Code hooks and the Codex notify wrapper.
//
// Usage:
//   agentkeeper-hook claude-code notification
//   agentkeeper-hook codex notify <json-arg>
//
// Reads hook JSON from stdin (Claude Code) or accepts an inline JSON arg (Codex).
// Writes a status file. Never writes to stdout. Always exits 0.

@inline(__always)
func logErr(_ msg: String) {
    let line = "agentkeeper-hook: \(msg)\n"
    FileHandle.standardError.write(line.data(using: .utf8) ?? Data())
}

func homeDir() -> URL {
    URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
}

func statusDir() -> URL {
    homeDir()
        .appendingPathComponent("Library/Application Support/AgentKeeper/status", isDirectory: true)
}

func ensureDir(_ url: URL) {
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
}

func atomicWrite(_ data: Data, to url: URL) {
    ensureDir(url.deletingLastPathComponent())
    let dir = url.deletingLastPathComponent()
    let tmp = dir.appendingPathComponent(".\(url.lastPathComponent).tmp.\(getpid()).\(UInt64.random(in: 0...UInt64.max))", isDirectory: false)
    guard FileManager.default.createFile(atPath: tmp.path, contents: data, attributes: nil) else { return }
    let fd = open(tmp.path, O_WRONLY)
    if fd >= 0 { _ = fsync(fd); close(fd) }
    if rename(tmp.path, url.path) != 0 {
        try? FileManager.default.removeItem(at: tmp)
    }
}

func nowMillis() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

func readStdin(maxBytes: Int = 64 * 1024) -> Data {
    let handle = FileHandle.standardInput
    var buf = Data()
    while let chunk = try? handle.read(upToCount: 4096), !chunk.isEmpty {
        buf.append(chunk)
        if buf.count >= maxBytes { break }
    }
    return buf
}

func jsonString(_ d: [String: Any]) -> Data? {
    try? JSONSerialization.data(withJSONObject: d, options: [.sortedKeys, .withoutEscapingSlashes])
}

func writeStatus(
    agent: String,
    sessionId: String,
    displayName: String,
    projectPath: String?,
    pid: Int32?,
    state: String,
    lastEvent: String?
) {
    let id = "\(agent)__\(sessionId)"
    let now = nowMillis()
    var payload: [String: Any] = [
        "agent": agent,
        "sessionId": sessionId,
        "displayName": displayName,
        "state": state,
        "lastTransitionAt": now,
        "lastHeartbeatAt": now,
    ]
    if let projectPath { payload["projectPath"] = projectPath }
    if let pid { payload["pid"] = Int(pid) }
    if let lastEvent { payload["lastEvent"] = lastEvent }
    guard let data = jsonString(payload) else { return }
    let url = statusDir().appendingPathComponent("\(id).json", isDirectory: false)
    atomicWrite(data, to: url)
}

// MARK: - Subcommands

func handleClaudeCodeNotification() {
    let raw = readStdin()
    guard !raw.isEmpty else {
        logErr("claude-code notification: empty stdin")
        return
    }
    guard let obj = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] else {
        logErr("claude-code notification: stdin was not a JSON object")
        return
    }
    let sessionId = (obj["session_id"] as? String) ?? (obj["sessionId"] as? String) ?? ""
    let cwd = (obj["cwd"] as? String) ?? (obj["transcript_path"] as? String) ?? ""
    let message = (obj["message"] as? String) ?? "needs attention"
    let displayName: String = {
        if !cwd.isEmpty {
            return URL(fileURLWithPath: cwd).lastPathComponent
        }
        return "Claude Code"
    }()
    guard !sessionId.isEmpty else {
        logErr("claude-code notification: missing session_id; keys=\(Array(obj.keys))")
        return
    }
    writeStatus(
        agent: "claude-code",
        sessionId: sessionId,
        displayName: displayName,
        projectPath: cwd.isEmpty ? nil : cwd,
        pid: nil,
        state: "waiting",
        lastEvent: message
    )
}

func handleCodexNotify(_ jsonArg: String?) {
    // Codex passes a single JSON string arg via the `notify` config.
    guard let s = jsonArg, let data = s.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        logErr("codex notify: missing or non-JSON arg")
        return
    }
    let type = (obj["type"] as? String) ?? "unknown"
    // Best-effort session identity. Codex's notify payload commonly carries
    // turn-id or session-id depending on version; we keep both branches.
    let sessionId = (obj["session-id"] as? String)
        ?? (obj["session_id"] as? String)
        ?? (obj["thread-id"] as? String)
        ?? "active"
    let cwd = (obj["cwd"] as? String)
    let displayName: String = {
        if let c = cwd { return URL(fileURLWithPath: c).lastPathComponent }
        return "Codex"
    }()

    let state: String
    switch type {
    case "agent-turn-complete", "turn-ended", "agent-message":
        state = "idle"
    case "approval-requested":
        state = "waiting"
    default:
        state = "working"
    }

    writeStatus(
        agent: "codex-cli",
        sessionId: sessionId,
        displayName: displayName,
        projectPath: cwd,
        pid: nil,
        state: state,
        lastEvent: type
    )
}

// MARK: - Entry

let args = CommandLine.arguments
guard args.count >= 3 else {
    logErr("usage: agentkeeper-hook <agent> <event> [json]")
    exit(0)
}

let agent = args[1]
let event = args[2]

switch (agent, event) {
case ("claude-code", "notification"):
    handleClaudeCodeNotification()
case ("codex", "notify"):
    handleCodexNotify(args.count >= 4 ? args[3] : nil)
default:
    logErr("unknown subcommand: \(agent) \(event)")
}

exit(0)
