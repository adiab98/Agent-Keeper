import Foundation
import os

/// Centralised `os.Logger` categories. Until now the detection paths swallowed
/// every failure with `try?` and never logged, which made the app impossible
/// to debug when a tool changed its on-disk format or a permission was denied.
///
/// Stream live with:
///   log stream --predicate 'subsystem == "com.ahmeddiab.agentkeeper"' --level debug
public enum AKLog {
    public static let subsystem = "com.ahmeddiab.agentkeeper"

    public static let claudeCode = Logger(subsystem: subsystem, category: "claude-code")
    public static let claudeDesktop = Logger(subsystem: subsystem, category: "claude-desktop")
    public static let claudeCowork = Logger(subsystem: subsystem, category: "claude-cowork")
    public static let codexCLI = Logger(subsystem: subsystem, category: "codex-cli")
    public static let codexDesktop = Logger(subsystem: subsystem, category: "codex-desktop")
    public static let ax = Logger(subsystem: subsystem, category: "accessibility")
    public static let io = Logger(subsystem: subsystem, category: "io")
    public static let installer = Logger(subsystem: subsystem, category: "installer")
    public static let app = Logger(subsystem: subsystem, category: "app")
}

/// Thread-safe, in-memory snapshot of each producer's health so the menu-bar
/// Diagnostics view can show, at a glance, what is and isn't working. Producers
/// run on their own dispatch queues; this records from any thread and exposes a
/// `snapshot()` the UI polls on the main thread.
public final class DetectionDiagnostics: @unchecked Sendable {
    public static let shared = DetectionDiagnostics()

    public struct ProducerStat: Sendable, Equatable {
        public var lastScanAt: Date?
        public var lastError: String?
        public var lastErrorAt: Date?
        public var discovered: Int = 0
        public var written: Int = 0
        public var errors: Int = 0
    }

    private let lock = NSLock()
    private var stats: [String: ProducerStat] = [:]

    private init() {}

    /// Record the outcome of one producer scan.
    public func recordScan(_ key: String, discovered: Int, written: Int, errors: Int, at now: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        var s = stats[key] ?? ProducerStat()
        s.lastScanAt = now
        s.discovered = discovered
        s.written = written
        s.errors = errors
        stats[key] = s
    }

    /// Record a recoverable failure (file read, parse, write, permission).
    public func recordError(_ key: String, _ message: String, at now: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        var s = stats[key] ?? ProducerStat()
        s.lastError = message
        s.lastErrorAt = now
        s.errors += 1
        stats[key] = s
    }

    public func snapshot() -> [String: ProducerStat] {
        lock.lock(); defer { lock.unlock() }
        return stats
    }
}

/// Writes a status row, logging and recording any failure instead of letting it
/// vanish into a `try?`. Returns true on success so callers can count writes.
@discardableResult
public func akWrite(_ status: SessionStatus, to store: StatusStore, logger: Logger, key: String) -> Bool {
    do {
        try store.write(status)
        return true
    } catch {
        logger.error("status write failed for \(status.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
        DetectionDiagnostics.shared.recordError(key, "write \(status.id): \(error.localizedDescription)")
        return false
    }
}
