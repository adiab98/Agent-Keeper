import Foundation

/// Pure logic for the Codex `notify` wrapper, extracted from the app-target
/// `CodexNotifyInstaller` so it can be unit tested. The whole reason this
/// exists: an earlier build let the wrapper forward to *itself* (because
/// `install()` runs on every launch and naively re-embedded whatever was in
/// `notify = [...]` — which, after the first install, is the wrapper). That
/// produced infinite recursion and killed Codex CLI detection.
public enum CodexWrapper {
    /// Resolves the genuine "previous notify program" to embed in the wrapper,
    /// guaranteeing the result never points back at the wrapper itself.
    ///
    /// - Parameters:
    ///   - wrapperPath: absolute path of the wrapper script.
    ///   - configArray: the `notify = [...]` array currently in config.toml.
    ///   - existingWrapperOriginal: the `ORIGINAL=` target read from an
    ///     already-installed wrapper (empty if none / not installed).
    public static func resolveForwardTarget(
        wrapperPath: String,
        configArray: [String],
        existingWrapperOriginal: [String]
    ) -> [String] {
        let raw: [String]
        if configArray.contains(where: { samePath($0, wrapperPath) }) {
            // Config already points at us → the real prior program lives inside
            // the existing wrapper. Recover it (and strip self-refs below, which
            // repairs a previously-corrupted wrapper).
            raw = existingWrapperOriginal
        } else {
            raw = configArray
        }
        return raw.filter { !samePath($0, wrapperPath) }
    }

    public static func samePath(_ a: String, _ b: String) -> Bool {
        URL(fileURLWithPath: a).standardizedFileURL.path
            == URL(fileURLWithPath: b).standardizedFileURL.path
    }
}
