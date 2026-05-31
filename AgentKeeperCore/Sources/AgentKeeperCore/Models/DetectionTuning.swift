import Foundation

/// All detection timing constants in one place. Previously these magic numbers
/// were scattered across producers (a 4s window here, a 5s window there, a 30s
/// throttle elsewhere) with no documentation of why, which made the
/// working/idle signal inconsistent and impossible to reason about. Centralising
/// them keeps the behaviour consistent and lets the test suite pin the values.
public enum DetectionTuning {
    // MARK: Poll cadence (seconds)
    public static let claudeSessionsPoll: Int = 1
    public static let claudeDesktopPoll: Int = 3
    public static let claudeCoworkPoll: Int = 2
    public static let codexCLIPoll: Int = 2
    public static let codexDesktopPoll: Int = 2

    // MARK: "Working" inference windows
    /// Claude Desktop infers `working` while `bridge-state.json` keeps changing.
    /// Widened from the original 4s: a slow model that pauses briefly between
    /// tool calls should not flip to `idle` mid-turn. Paired with
    /// `claudeDesktopIdleHysteresis` so a row already shown as working needs a
    /// longer quiet stretch before it drops to idle (anti-flap).
    public static let claudeDesktopWorkingWindow: TimeInterval = 10
    public static let claudeDesktopIdleHysteresis: TimeInterval = 4

    /// Codex Desktop / Cowork: when no `task_started`/`task_complete` marker is
    /// found in the scanned tail, fall back to "file grew within N seconds".
    public static let rolloutMTimeWorkingWindow: TimeInterval = 5

    // MARK: Active windows (drop sessions older than this)
    public static let codexCLIActiveWindow: TimeInterval = 10 * 60
    public static let codexDesktopActiveWindow: TimeInterval = 30 * 60
    public static let claudeCoworkActiveWindow: TimeInterval = 60 * 60

    // MARK: Heartbeat throttles (skip rewrite when unchanged within this)
    public static let claudeSessionsHeartbeat: TimeInterval = 30
    public static let claudeDesktopHeartbeat: TimeInterval = 10
    public static let codexCLIHeartbeat: TimeInterval = 30
    public static let coworkHeartbeat: TimeInterval = 8
    public static let codexDesktopHeartbeat: TimeInterval = 8

    // MARK: File scan bounds
    public static let rolloutScanChunk: UInt64 = 262_144        // 256 KB
    public static let rolloutScanCap: UInt64 = 4 * 1024 * 1024  // 4 MB
    public static let auditTailBytes: UInt64 = 8192

    // MARK: Reaping
    public static let gracePeriod: TimeInterval = 6
}
