import SwiftUI
import AgentKeeperCore

struct StatusIcon: View {
    let state: AgentState

    var body: some View {
        // MenuBarExtra labels render best with a single plain Image. Avoid
        // TimelineView or invalid SF Symbol names — SwiftUI will silently
        // substitute and the icon ends up looking wrong.
        switch state {
        case .waiting:
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundColor(.red)
        case .working:
            Image(systemName: "circle.fill")
        case .idle:
            Image(systemName: "circle.dotted")
        }
    }
}
