import Foundation
import ApplicationServices
import AppKit

/// Reads dock-icon badges (the small red numbers/labels) for any running app
/// by querying the Dock's accessibility tree. Codex and Claude Desktop both
/// surface "this chat needs your attention" via the dock badge — which is
/// readable via the standard Accessibility permission the user has already
/// granted for the wider AX integration.
///
/// The Dock exposes each running app as an `AXDockItem` directly under
/// `AXChildren`; no deep walk needed. Badge text comes from the
/// `AXStatusLabel` attribute. Empty / missing label = no badge.
public enum DockBadgeReader {
    /// Returns the badge label for the dock icon whose title equals `appName`
    /// (case-insensitive), or nil if the app isn't in the dock, the dock
    /// item has no badge, or Accessibility isn't granted.
    public static func badge(forAppNamed appName: String) -> String? {
        guard AccessibilityProbe.isTrusted() else { return nil }
        guard let dockPid = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first?.processIdentifier else {
            return nil
        }
        let dock = AXUIElementCreateApplication(dockPid)
        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(dock, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let level1 = childrenRef as? [AXUIElement] else {
            return nil
        }

        // The Dock's structure varies slightly across macOS versions: items
        // are sometimes children of an `AXList` rather than direct children.
        // Scan one level deep to be safe.
        let candidates: [AXUIElement] = level1.flatMap { item -> [AXUIElement] in
            var inner: CFTypeRef?
            if AXUIElementCopyAttributeValue(item, kAXChildrenAttribute as CFString, &inner) == .success,
               let arr = inner as? [AXUIElement] {
                return [item] + arr
            }
            return [item]
        }

        let target = appName.lowercased()
        for item in candidates {
            let title = (attributeString(item, "AXTitle") ?? "").lowercased()
            // Tolerant match: the dock title is sometimes the display name
            // ("Claude") and sometimes a longer variant. Accept an exact match
            // or either string containing the other so a small naming drift
            // (e.g. "Codex" vs "OpenAI Codex") doesn't silently lose the badge.
            guard !title.isEmpty,
                  title == target || title.contains(target) || target.contains(title) else { continue }
            // kAXStatusLabelAttribute isn't always bridged to a Swift constant
            // depending on SDK version; the raw attribute name is stable.
            if let label = attributeString(item, "AXStatusLabel"), !label.isEmpty {
                return label
            }
        }
        return nil
    }

    private static func attributeString(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }
}
