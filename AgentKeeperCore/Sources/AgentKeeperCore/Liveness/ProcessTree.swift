import Foundation
import Darwin
import AppKit

/// Lightweight process-tree lookup used to map a Claude Code session pid
/// back to its hosting terminal app. We need this so "user focused the
/// terminal" can clear a stuck `.waiting` row.
public enum ProcessTree {
    /// Returns the parent pid of `pid`, or nil if it cannot be determined
    /// (process gone, ppid==0, etc.).
    public static func parentPid(of pid: Int32) -> Int32? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var size = MemoryLayout<kinfo_proc>.stride
        var kproc = kinfo_proc()
        let result = withUnsafeMutablePointer(to: &kproc) { ptr in
            sysctl(&mib, u_int(mib.count), ptr, &size, nil, 0)
        }
        guard result == 0, size > 0 else { return nil }
        let ppid = kproc.kp_eproc.e_ppid
        return ppid > 0 ? ppid : nil
    }

    /// Walks up `pid`'s parent chain up to `maxDepth` hops. Returns true if
    /// `ancestor` appears anywhere in that chain.
    public static func isDescendant(_ pid: Int32, of ancestor: Int32, maxDepth: Int = 16) -> Bool {
        if pid <= 0 || ancestor <= 0 { return false }
        if pid == ancestor { return true }
        var current = pid
        for _ in 0..<maxDepth {
            guard let parent = parentPid(of: current) else { return false }
            if parent == ancestor { return true }
            if parent == 1 || parent == 0 { return false } // reached launchd / kernel
            current = parent
        }
        return false
    }

    /// Walks up `pid`'s parent chain. Returns true if any pid in the chain
    /// matches `ancestorPid` OR has an `NSRunningApplication.bundleIdentifier`
    /// equal to `bundleId`. The bundle-id branch handles terminal apps that
    /// fork shells under helper processes whose pid differs from the main
    /// app's pid (e.g., Warp, some custom Ghostty setups). Either is enough.
    public static func isDescendant(
        _ pid: Int32,
        ofAppPid ancestorPid: Int32,
        orBundleId bundleId: String?,
        maxDepth: Int = 16
    ) -> Bool {
        if pid <= 0 { return false }
        if pid == ancestorPid { return true }
        var current = pid
        for _ in 0..<maxDepth {
            // Bundle-id match at this hop?
            if let bundleId,
               let app = NSRunningApplication(processIdentifier: current),
               app.bundleIdentifier == bundleId {
                return true
            }
            guard let parent = parentPid(of: current) else { return false }
            if parent == ancestorPid { return true }
            if parent == 1 || parent == 0 { return false }
            current = parent
        }
        return false
    }
}
