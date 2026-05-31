import AppKit
import UserNotifications
import AgentKeeperCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    var store: AppStore?
    var statusBarController: StatusBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppPaths.bootstrap()
        NSApp.setActivationPolicy(.accessory)
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }

        let s = AppStore()
        self.store = s
        self.statusBarController = StatusBarController(store: s)

        autoInstall()
    }

    /// Silently bring every available integration up to date.
    /// No permissions are required — every path we touch is in the user's
    /// home and not TCC-protected.
    private func autoInstall() {
        DispatchQueue.global(qos: .utility).async {
            let connected = self.runAllInstallers()
            let firstRun = !UserDefaults.standard.bool(forKey: "agentkeeper.firstRunNotified")
            UserDefaults.standard.set(true, forKey: "agentkeeper.firstRunNotified")
            if firstRun, !connected.isEmpty {
                self.postWelcomeNotification(connected: connected)
            }
        }
    }

    private func runAllInstallers() -> [String] {
        var connected: [String] = []
        _ = try? HookBinaryInstaller.install()

        let fm = FileManager.default
        if fm.fileExists(atPath: AppPaths.claudeSettings.deletingLastPathComponent().path) {
            if (try? ClaudeHookInstaller.install()) != nil {
                connected.append("Claude Code")
            }
        }
        if fm.fileExists(atPath: AppPaths.codexConfig.deletingLastPathComponent().path) {
            if (try? CodexNotifyInstaller.install()) != nil {
                connected.append("Codex CLI")
            }
        }
        return connected
    }

    private func postWelcomeNotification(connected: [String]) {
        let content = UNMutableNotificationContent()
        content.title = "Agent Keeper is watching"
        content.body = "Connected to " + connected.joined(separator: " and ") + ". You'll hear from me when an agent needs you."
        content.sound = .default
        let req = UNNotificationRequest(identifier: "agentkeeper.welcome", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
    }
}
