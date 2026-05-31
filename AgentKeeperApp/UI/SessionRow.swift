import SwiftUI
import AgentKeeperCore

struct SessionRow: View {
    let status: SessionStatus

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: stateSymbol)
                .foregroundStyle(stateColor)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 14)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Image(systemName: status.agent.symbolName)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text(status.displayName)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Spacer()
                    Text(relativeTime)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                Text(eventLine)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .contentShape(Rectangle())
        .padding(.vertical, 4)
    }

    private var stateSymbol: String {
        switch status.state {
        case .waiting: return "exclamationmark.circle.fill"
        case .working: return "circle.dotted.circle"
        case .idle: return "circle"
        }
    }

    private var stateColor: Color {
        switch status.state {
        case .waiting: return .red
        case .working: return .accentColor
        case .idle: return .secondary
        }
    }

    private var eventLine: String {
        let agentLabel = status.agent.displayName
        let stateLabel: String = {
            switch status.state {
            case .waiting: return "waiting"
            case .working: return "working"
            case .idle: return "idle"
            }
        }()
        if let evt = status.lastEvent, !evt.isEmpty {
            return "\(agentLabel) · \(stateLabel) · \(evt)"
        }
        return "\(agentLabel) · \(stateLabel)"
    }

    private var relativeTime: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: status.lastTransitionAt, relativeTo: Date())
    }
}
