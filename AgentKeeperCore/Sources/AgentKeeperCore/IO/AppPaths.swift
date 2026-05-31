import Foundation

public enum AppPaths {
    public static var home: URL {
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    }

    public static var applicationSupport: URL {
        home
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("AgentKeeper", isDirectory: true)
    }

    public static var statusDirectory: URL {
        applicationSupport.appendingPathComponent("status", isDirectory: true)
    }

    public static var binDirectory: URL {
        applicationSupport.appendingPathComponent("bin", isDirectory: true)
    }

    public static var backupsDirectory: URL {
        applicationSupport.appendingPathComponent("backups", isDirectory: true)
    }

    public static var hookBinary: URL {
        binDirectory.appendingPathComponent("agentkeeper-hook", isDirectory: false)
    }

    public static var codexNotifyWrapper: URL {
        binDirectory.appendingPathComponent("codex-notify-wrap.sh", isDirectory: false)
    }

    public static var claudeSettings: URL {
        home.appendingPathComponent(".claude/settings.json", isDirectory: false)
    }

    public static var claudeSessionsDir: URL {
        home.appendingPathComponent(".claude/sessions", isDirectory: true)
    }

    public static var claudeDaemonRoster: URL {
        home.appendingPathComponent(".claude/daemon/roster.json", isDirectory: false)
    }

    public static var codexConfig: URL {
        home.appendingPathComponent(".codex/config.toml", isDirectory: false)
    }

    public static var codexSessionIndex: URL {
        home.appendingPathComponent(".codex/session_index.jsonl", isDirectory: false)
    }

    public static var codexSessionsDir: URL {
        home.appendingPathComponent(".codex/sessions", isDirectory: true)
    }

    public static var claudeDesktopAppSupport: URL {
        home.appendingPathComponent("Library/Application Support/Claude", isDirectory: true)
    }

    public static var claudeDesktopBridgeState: URL {
        claudeDesktopAppSupport.appendingPathComponent("bridge-state.json", isDirectory: false)
    }

    public static var claudeDesktopMainLog: URL {
        home.appendingPathComponent("Library/Logs/Claude/main.log", isDirectory: false)
    }

    public static var claudeDesktopCoworkdLog: URL {
        home.appendingPathComponent("Library/Logs/Claude/coworkd.log", isDirectory: false)
    }

    public static var codexDesktopLogsDir: URL {
        home.appendingPathComponent("Library/Logs/com.openai.codex", isDirectory: true)
    }

    @discardableResult
    public static func ensureDirectory(_ url: URL) -> Bool {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
            return true
        }
        do {
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
            return true
        } catch {
            return false
        }
    }

    public static func bootstrap() {
        ensureDirectory(applicationSupport)
        ensureDirectory(statusDirectory)
        ensureDirectory(binDirectory)
        ensureDirectory(backupsDirectory)
    }
}
