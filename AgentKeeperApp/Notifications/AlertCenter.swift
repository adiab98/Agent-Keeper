import Foundation
import UserNotifications
import AppKit
import AgentKeeperCore

final class AlertCenter {
    private var soundName: String {
        UserDefaults.standard.string(forKey: "agentkeeper.sound") ?? "Glass"
    }

    func fire(for status: SessionStatus) {
        let content = UNMutableNotificationContent()
        content.title = "\(status.agent.displayName) is waiting"
        content.subtitle = status.displayName
        if let e = status.lastEvent { content.body = e }
        content.sound = .default
        let req = UNNotificationRequest(identifier: status.id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
        NSSound(named: NSSound.Name(soundName))?.play()
    }
}
