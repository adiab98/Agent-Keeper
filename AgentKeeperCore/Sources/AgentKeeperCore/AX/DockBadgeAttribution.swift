import Foundation

/// Decides which per-chat session row an app-level dock badge ("N chats need
/// attention") should be attributed to.
///
/// The dock badge is an app-wide signal: it tells us *some* conversation in
/// Codex Desktop / Claude Cowork wants the user, but not which one. We attach
/// it to the most-recently-active session that is **not** currently working —
/// a working chat is mid-turn and by definition not awaiting the user, so an
/// app-wide badge must never override its `.working` state (that produced
/// false "Needs attention" rows for actively-streaming chats).
///
/// Returns the index into `candidates` to flag as `.waiting`, or `nil` when
/// every candidate is working (the badge belongs to a chat we can't pinpoint,
/// and flagging a working one would be wrong).
enum DockBadgeAttribution {
    static func target(_ candidates: [(state: AgentState, mtime: Date)]) -> Int? {
        candidates.enumerated()
            .filter { $0.element.state != .working }
            .max { $0.element.mtime < $1.element.mtime }?
            .offset
    }
}
