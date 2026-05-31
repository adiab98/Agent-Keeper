import Foundation
import Darwin
import AgentKeeperCore

enum HookBinaryInstaller {
    enum InstallError: Error, LocalizedError {
        case bundledHookMissing
        case copyFailed(String)

        var errorDescription: String? {
            switch self {
            case .bundledHookMissing: return "Bundled agentkeeper-hook binary not found inside the app bundle."
            case .copyFailed(let s): return "Failed to install hook binary: \(s)"
            }
        }
    }

    /// Path to the bundled hook binary inside the .app
    static var bundledHookURL: URL? {
        guard let exec = Bundle.main.executableURL else { return nil }
        let candidate = exec.deletingLastPathComponent().appendingPathComponent("agentkeeper-hook", isDirectory: false)
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
    }

    /// Where we copy the hook to (survives the .app moving / being deleted).
    static var installedHookURL: URL { AppPaths.hookBinary }

    static var isInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: installedHookURL.path)
    }

    @discardableResult
    static func install(force: Bool = false) throws -> URL {
        AppPaths.bootstrap()
        guard let src = bundledHookURL else { throw InstallError.bundledHookMissing }
        let dst = installedHookURL
        let fm = FileManager.default

        if fm.fileExists(atPath: dst.path) {
            if !force, sameContent(src: src, dst: dst) {
                stripQuarantine(dst)
                return dst
            }
            try? fm.removeItem(at: dst)
        }

        do {
            try fm.copyItem(at: src, to: dst)
        } catch {
            throw InstallError.copyFailed(error.localizedDescription)
        }

        // Ensure executable bits via chmod syscall (more reliable than
        // FileManager.setAttributes across edge cases).
        dst.path.withCString { _ = chmod($0, 0o755) }
        stripQuarantine(dst)
        return dst
    }

    static func uninstall() {
        try? FileManager.default.removeItem(at: installedHookURL)
    }

    private static func sameContent(src: URL, dst: URL) -> Bool {
        guard let a = try? Data(contentsOf: src),
              let b = try? Data(contentsOf: dst) else { return false }
        return a == b
    }

    private static func stripQuarantine(_ url: URL) {
        url.path.withCString { c in
            _ = removexattr(c, "com.apple.quarantine", 0)
        }
    }
}
