import AppKit
import SwiftUI
import Combine
import AgentKeeperCore

/// AppKit-backed menu bar item. SwiftUI's MenuBarExtra has been unreliable on
/// macOS 14/15/26 — clicks sometimes don't open the window. NSStatusItem +
/// NSPopover has worked since 10.7.
@MainActor
final class StatusBarController {
    private let statusItem: NSStatusItem
    private let popover: NSPopover
    private let store: AppStore
    private var observers: [AnyCancellable] = []

    init(store: AppStore) {
        self.store = store
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.popover = NSPopover()
        self.popover.behavior = .transient
        self.popover.contentViewController = NSHostingController(
            rootView: MenuBarView().environmentObject(store)
        )
        self.popover.contentSize = NSSize(width: 360, height: 400)

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopover(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        applyIcon(state: store.overallState)

        // Re-render the icon whenever overall state changes.
        store.$overallState
            .receive(on: RunLoop.main)
            .sink { [weak self] state in self?.applyIcon(state: state) }
            .store(in: &observers)
    }

    private func applyIcon(state: AgentState) {
        guard let button = statusItem.button else { return }
        let symbol: String
        let useTemplate: Bool
        let tint: NSColor?
        switch state {
        case .waiting:
            symbol = "exclamationmark.circle.fill"
            useTemplate = false
            tint = .systemRed
        case .working:
            symbol = "circle.fill"
            useTemplate = true
            tint = nil
        case .idle:
            symbol = "circle.dotted"
            useTemplate = true
            tint = nil
        }
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: state.rawValue)?
            .withSymbolConfiguration(config)
        image?.isTemplate = useTemplate
        if let image, let tint, !useTemplate {
            let tinted = NSImage(size: image.size, flipped: false) { rect in
                image.draw(in: rect)
                tint.set()
                rect.fill(using: .sourceAtop)
                return true
            }
            tinted.isTemplate = false
            button.image = tinted
        } else {
            button.image = image
        }
        button.imagePosition = .imageOnly
    }

    @objc private func togglePopover(_ sender: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(sender)
        } else {
            // Pull a fresh disk snapshot before showing so the menu can never
            // be stale relative to what producers have written.
            store.refreshFromDisk()
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}
