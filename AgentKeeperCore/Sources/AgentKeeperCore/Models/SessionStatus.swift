import Foundation

public struct SessionStatus: Codable, Hashable, Identifiable, Sendable {
    public var agent: AgentKind
    public var sessionId: String
    public var displayName: String
    public var projectPath: String?
    public var pid: Int32?
    public var state: AgentState
    public var lastTransitionAt: Date
    public var lastHeartbeatAt: Date
    public var lastEvent: String?

    public init(
        agent: AgentKind,
        sessionId: String,
        displayName: String,
        projectPath: String? = nil,
        pid: Int32? = nil,
        state: AgentState,
        lastTransitionAt: Date = Date(),
        lastHeartbeatAt: Date = Date(),
        lastEvent: String? = nil
    ) {
        self.agent = agent
        self.sessionId = sessionId
        self.displayName = displayName
        self.projectPath = projectPath
        self.pid = pid
        self.state = state
        self.lastTransitionAt = lastTransitionAt
        self.lastHeartbeatAt = lastHeartbeatAt
        self.lastEvent = lastEvent
    }

    public var id: String { "\(agent.rawValue)__\(sessionId)" }

    public var statusFileName: String { "\(id).json" }
}
