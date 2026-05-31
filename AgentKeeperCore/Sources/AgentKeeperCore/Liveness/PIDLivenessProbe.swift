import Foundation
import Darwin

public enum PIDLivenessProbe {
    public static func isAlive(_ pid: Int32) -> Bool {
        if pid <= 0 { return false }
        let result = kill(pid, 0)
        if result == 0 { return true }
        return errno != ESRCH
    }
}
