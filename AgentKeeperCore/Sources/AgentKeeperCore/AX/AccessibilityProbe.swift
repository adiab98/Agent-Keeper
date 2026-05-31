import Foundation
import ApplicationServices
import AppKit

/// Walks another app's accessibility tree looking for an unambiguous
/// "needs-attention" UI pattern (a cluster of approve/deny-style buttons).
///
/// Design choices for accuracy and zero workflow interruption:
/// - **Opt-in**: callers gate this behind a UserDefault. We never prompt
///   for Accessibility access on our own.
/// - **Strict matching**: a single "Cancel" button is not enough. We require
///   `minMatches` distinct positive buttons (Approve / Allow / Run / Yes /
///   Continue) visible simultaneously. False positives stay near zero.
/// - **Bounded walk**: depth-capped + node-capped recursion so even pathological
///   web-view trees (Electron) can't stall the producer thread.
public enum AccessibilityProbe {
    public static func isTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    /// Prompts the user via the standard system dialog. Safe to call from any
    /// thread. The dialog opens System Settings — the user adds Agent Keeper
    /// to the Accessibility list and the app picks up the change on next poll.
    public static func requestTrust() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as NSString
        let opts: NSDictionary = [key: true]
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    /// Default positive-match needles. Case-insensitive substring match.
    /// "Cancel" / "Deny" are deliberately NOT here — those appear on plenty
    /// of non-attention dialogs.
    public static let defaultPositiveNeedles: [String] = [
        "approve",
        "allow",
        "run",
        "continue",
        "yes, run",
        "always allow",
        "proceed",
        "confirm",
    ]

    /// "Strong" needles unambiguous enough that a SINGLE match inside an app
    /// *window* (we never scan the menu bar) is enough to call it an approval
    /// prompt. This fixes the previous gap where a standard one-button
    /// "Allow" / "Approve" dialog (its sibling being "Deny", which is not a
    /// positive needle) failed the ≥2-distinct-needle rule and went undetected.
    public static let strongPositiveNeedles: [String] = [
        "always allow",
        "yes, run",
        "yes, proceed",
        "approve",
        "allow",
    ]

    /// "Stop" / "Pause" style needles — these appear in agent chat UIs only
    /// while the model is actively generating, and are replaced by a Send
    /// button when generation finishes. Reliable working-state signal.
    public static let workingNeedles: [String] = [
        "stop generating",
        "stop response",
        "stop ",      // trailing space catches "Stop" by itself, avoids "Stops"
        "pause",
    ]

    public enum ActivityState: Equatable {
        case working
        case waiting
        case none
    }

    /// Returns the title of the currently focused window of the given app's
    /// pid, or nil if it can't be read. Used to map a focused terminal back
    /// to the agent session it hosts (when daemon-spawned processes break
    /// the PPID chain).
    public static func focusedWindowTitle(of pid: Int32) -> String? {
        guard isTrusted() else { return nil }
        let app = AXUIElementCreateApplication(pid)
        var windowRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &windowRef) == .success,
              let window = windowRef else { return nil }
        // CFTypeRef is AXUIElement here; force-bridge through unsafe cast.
        let windowEl = window as! AXUIElement
        var titleRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(windowEl, kAXTitleAttribute as CFString, &titleRef) == .success,
              let title = titleRef as? String else { return nil }
        return title
    }

    /// Walks the app's window tree (NOT its menus) looking for approval-style
    /// buttons. Returns `.waiting` only when at least two distinct positive
    /// needles match. `.working` detection via UI button labels turned out
    /// to be unreliable (apps have plenty of incidental "Stop X" controls in
    /// menus and toolbars), so we don't synthesize it here.
    public static func detectActivity(pid: Int32, maxDepth: Int = 8, maxNodes: Int = 400) -> ActivityState {
        guard isTrusted() else { return .none }
        let app = AXUIElementCreateApplication(pid)
        // Restrict to AXWindow descendants only. App-level children also
        // include AXMenuBar (always present, full of "Stop X" type items)
        // which is too noisy.
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement], !windows.isEmpty else {
            return .none
        }

        var titles: [String] = []
        let counter = NodeCounter(limit: maxNodes)
        for window in windows {
            walk(window, depth: 0, maxDepth: maxDepth, counter: counter) { element in
                if counter.exceeded { return false }
                let role = string(of: element, attribute: kAXRoleAttribute as CFString) ?? ""
                guard role == "AXButton" || role == "AXRadioButton" else {
                    return true
                }
                let title = (string(of: element, attribute: kAXTitleAttribute as CFString)
                    ?? string(of: element, attribute: kAXDescriptionAttribute as CFString)
                    ?? "")
                    .lowercased()
                if !title.isEmpty { titles.append(title) }
                return true
            }
        }
        return classify(buttonTitles: titles)
    }

    /// Pure approval-prompt classifier, extracted from the AX walk so it can be
    /// unit tested. `.waiting` when any *strong* needle matches a button, OR
    /// when at least `minMatches` distinct general needles match.
    public static func classify(
        buttonTitles: [String],
        strong: [String] = strongPositiveNeedles,
        weak: [String] = defaultPositiveNeedles,
        minMatches: Int = 2
    ) -> ActivityState {
        var weakHits: Set<String> = []
        for title in buttonTitles {
            let t = title.lowercased()
            for needle in strong where t.contains(needle) {
                return .waiting
            }
            for needle in weak where t.contains(needle) {
                weakHits.insert(needle)
            }
        }
        return weakHits.count >= minMatches ? .waiting : .none
    }

    public static func hasApprovalUI(
        pid: Int32,
        positiveNeedles: [String] = defaultPositiveNeedles,
        minMatches: Int = 2,
        maxDepth: Int = 8,
        maxNodes: Int = 400
    ) -> Bool {
        guard isTrusted() else { return false }
        let app = AXUIElementCreateApplication(pid)
        var matched: Set<String> = []
        let counter = NodeCounter(limit: maxNodes)
        walk(app, depth: 0, maxDepth: maxDepth, counter: counter) { element in
            if counter.exceeded { return false }
            let role = string(of: element, attribute: kAXRoleAttribute as CFString) ?? ""
            guard role == "AXButton" || role == "AXMenuItem" || role == "AXRadioButton" else {
                return true
            }
            let title = (string(of: element, attribute: kAXTitleAttribute as CFString)
                ?? string(of: element, attribute: kAXDescriptionAttribute as CFString)
                ?? "")
                .lowercased()
            guard !title.isEmpty else { return true }
            for needle in positiveNeedles where title.contains(needle) {
                matched.insert(needle)
                if matched.count >= minMatches { return false }
            }
            return true
        }
        return matched.count >= minMatches
    }

    // MARK: - tree walk

    private final class NodeCounter {
        var visited = 0
        let limit: Int
        init(limit: Int) { self.limit = limit }
        var exceeded: Bool { visited >= limit }
    }

    private static func walk(
        _ element: AXUIElement,
        depth: Int,
        maxDepth: Int,
        counter: NodeCounter,
        visit: (AXUIElement) -> Bool
    ) {
        if depth > maxDepth || counter.exceeded { return }
        counter.visited += 1
        let keepGoing = visit(element)
        if !keepGoing { return }

        var children: CFTypeRef?
        let res = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children)
        guard res == .success, let array = children as? [AXUIElement] else { return }
        for child in array {
            walk(child, depth: depth + 1, maxDepth: maxDepth, counter: counter, visit: visit)
            if counter.exceeded { return }
        }
    }

    private static func string(of element: AXUIElement, attribute: CFString) -> String? {
        var value: CFTypeRef?
        let res = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard res == .success else { return nil }
        return value as? String
    }
}
