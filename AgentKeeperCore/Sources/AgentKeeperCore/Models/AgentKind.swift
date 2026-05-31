import Foundation

public enum AgentKind: String, Codable, CaseIterable, Sendable {
    case claudeCode = "claude-code"
    case codexCLI = "codex-cli"
    case claudeDesktop = "claude-desktop"
    case codexDesktop = "codex-desktop"
    case claudeCowork = "claude-cowork"

    public var displayName: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .codexCLI: return "Codex CLI"
        case .claudeDesktop: return "Claude Desktop"
        case .codexDesktop: return "Codex Desktop"
        case .claudeCowork: return "Claude Cowork"
        }
    }

    public var symbolName: String {
        switch self {
        case .claudeCode, .claudeDesktop, .claudeCowork: return "sparkle"
        case .codexCLI, .codexDesktop: return "chevron.left.forwardslash.chevron.right"
        }
    }
}

public enum AgentState: String, Codable, Sendable {
    case working
    case idle
    case waiting
}
