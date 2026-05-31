import SwiftUI
import AgentKeeperCore

@main
struct AgentKeeperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // No SwiftUI scenes — the app is driven by NSStatusItem (StatusBarController)
        // and an NSWindow for Preferences (PreferencesWindowController). A
        // `Settings { ... }` scene is intentionally omitted because in
        // `.accessory` activation mode it has no menu bar item to invoke it.
        Settings { EmptyView() }
    }
}
