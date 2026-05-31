import Foundation

/// Tracks which session IDs a producer is currently observing and only deletes
/// status rows after they've been continuously absent for ~6 seconds. Prevents
/// transient producer hiccups from causing rows to "blink" out of the UI.
///
/// Usage from a producer:
///
/// ```swift
/// private let reaper = GraceReaper()
/// // On every scan, after computing the current liveIds:
/// for id in reaper.reap(liveIds: liveIds, now: Date()) {
///     store.remove("\(agentPrefix)__\(id)")
/// }
/// ```
public final class GraceReaper {
    private let gracePeriod: TimeInterval
    private var missedSince: [String: Date] = [:]

    public init(gracePeriod: TimeInterval = DetectionTuning.gracePeriod) {
        self.gracePeriod = gracePeriod
    }

    /// Records the set of session IDs currently observed live. Returns the
    /// IDs that have been absent long enough that the caller should now delete
    /// their status rows. Once returned, the ID is forgotten — the caller is
    /// expected to actually drop the row.
    public func reap(liveIds: Set<String>, now: Date = Date()) -> [String] {
        // Anything currently live is "seen now" → drop its absence record.
        for id in liveIds { missedSince.removeValue(forKey: id) }

        // For sessions that disappeared, accumulate their missing-since time.
        // We only know about IDs that have ever been seen — but the caller's
        // semantic is "give me IDs to delete," so we depend on the caller
        // populating us via prior reap() calls. We track via the union of
        // (current missedSince keys) ∪ (any IDs we've heard of by being told
        // they're live before).
        // Simpler approach: producers should record `seenIds` separately. We
        // achieve the same effect by exposing observe(_:) and then reap()
        // computes the diff.
        let now = now
        var toDelete: [String] = []
        for (id, since) in missedSince where now.timeIntervalSince(since) >= gracePeriod {
            toDelete.append(id)
        }
        for id in toDelete { missedSince.removeValue(forKey: id) }
        return toDelete
    }

    /// Mark a session ID as missing as of `now` if it wasn't already tracked.
    /// Producers call this for every previously-known ID that isn't in this
    /// scan's liveIds.
    public func markMissing(_ id: String, now: Date = Date()) {
        if missedSince[id] == nil {
            missedSince[id] = now
        }
    }

    /// Convenience: given the previously-known IDs and the current liveIds,
    /// mark the disappeared ones missing and return any due for reaping.
    public func tick(previousIds: Set<String>, liveIds: Set<String>, now: Date = Date()) -> [String] {
        let disappeared = previousIds.subtracting(liveIds)
        for id in disappeared { markMissing(id, now: now) }
        return reap(liveIds: liveIds, now: now)
    }
}
