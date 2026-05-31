import Foundation
import AgentKeeperCore

/// Installs / uninstalls the single `Notification` hook in ~/.claude/settings.json
/// that points to our installed hook binary. Idempotent. Always backs up before
/// modifying.
enum ClaudeHookInstaller {
    enum InstallError: Error, LocalizedError {
        case parseFailed
        case writeFailed(String)
        var errorDescription: String? {
            switch self {
            case .parseFailed: return "Couldn't parse ~/.claude/settings.json"
            case .writeFailed(let s): return "Failed to write ~/.claude/settings.json: \(s)"
            }
        }
    }

    static var managedCommand: String {
        "\"\(AppPaths.hookBinary.path)\" claude-code notification"
    }

    static var isInstalled: Bool {
        guard let s = try? loadSettings() else { return false }
        return hasManagedNotificationHook(in: s)
    }

    @discardableResult
    static func install() throws -> URL {
        let url = AppPaths.claudeSettings
        let fm = FileManager.default
        AppPaths.ensureDirectory(url.deletingLastPathComponent())

        var settings: [String: Any]
        if fm.fileExists(atPath: url.path) {
            try backup(url, label: "claude-settings")
            settings = try loadSettings()
        } else {
            settings = [:]
        }

        var hooks = (settings["hooks"] as? [String: Any]) ?? [:]
        var notificationGroups = (hooks["Notification"] as? [[String: Any]]) ?? []

        // Remove any prior managed entry; we'll re-add a fresh one.
        notificationGroups = notificationGroups.compactMap { group -> [String: Any]? in
            var g = group
            if var inner = g["hooks"] as? [[String: Any]] {
                inner.removeAll { isManagedCommand($0["command"] as? String) }
                if inner.isEmpty {
                    return nil
                }
                g["hooks"] = inner
            }
            return g
        }

        notificationGroups.append([
            "hooks": [
                [
                    "type": "command",
                    "command": managedCommand,
                ]
            ]
        ])
        hooks["Notification"] = notificationGroups
        settings["hooks"] = hooks

        try writeSettings(settings, to: url)
        return url
    }

    static func uninstall() throws {
        let url = AppPaths.claudeSettings
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try backup(url, label: "claude-settings")
        var settings = try loadSettings()
        guard var hooks = settings["hooks"] as? [String: Any] else { return }
        guard var notificationGroups = hooks["Notification"] as? [[String: Any]] else { return }
        notificationGroups = notificationGroups.compactMap { group -> [String: Any]? in
            var g = group
            if var inner = g["hooks"] as? [[String: Any]] {
                inner.removeAll { isManagedCommand($0["command"] as? String) }
                if inner.isEmpty { return nil }
                g["hooks"] = inner
            }
            return g
        }
        if notificationGroups.isEmpty {
            hooks.removeValue(forKey: "Notification")
        } else {
            hooks["Notification"] = notificationGroups
        }
        if hooks.isEmpty {
            settings.removeValue(forKey: "hooks")
        } else {
            settings["hooks"] = hooks
        }
        try writeSettings(settings, to: url)
    }

    // MARK: - helpers

    private static func loadSettings() throws -> [String: Any] {
        let url = AppPaths.claudeSettings
        let data = (try? Data(contentsOf: url)) ?? Data("{}".utf8)
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw InstallError.parseFailed
        }
        return obj
    }

    private static func writeSettings(_ settings: [String: Any], to url: URL) throws {
        do {
            let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
            try AtomicJSONWriter.writeRaw(data, to: url)
        } catch {
            throw InstallError.writeFailed(error.localizedDescription)
        }
    }

    private static func hasManagedNotificationHook(in settings: [String: Any]) -> Bool {
        guard let hooks = settings["hooks"] as? [String: Any],
              let groups = hooks["Notification"] as? [[String: Any]]
        else { return false }
        for g in groups {
            if let inner = g["hooks"] as? [[String: Any]] {
                if inner.contains(where: { isManagedCommand($0["command"] as? String) }) {
                    return true
                }
            }
        }
        return false
    }

    private static func isManagedCommand(_ cmd: String?) -> Bool {
        guard let cmd else { return false }
        return cmd.contains(AppPaths.hookBinary.path) && cmd.contains("claude-code") && cmd.contains("notification")
    }

    private static func backup(_ url: URL, label: String) throws {
        AppPaths.ensureDirectory(AppPaths.backupsDirectory)
        let ts = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let dst = AppPaths.backupsDirectory.appendingPathComponent("\(label).\(ts).bak", isDirectory: false)
        try? FileManager.default.copyItem(at: url, to: dst)
    }
}
