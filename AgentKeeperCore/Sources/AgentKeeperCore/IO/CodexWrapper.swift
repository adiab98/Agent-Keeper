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

    // MARK: - TOML `notify` line parsing (narrow, line-based)

    /// Range of the top-level `notify = [...]` assignment in config.toml,
    /// including its trailing newline when present.
    public static func notifyLineRange(in text: String) -> Range<String.Index>? {
        guard let start = text.range(of: #"(^|\n)\s*notify\s*=\s*\["#, options: .regularExpression) else {
            return nil
        }
        // Move start to the beginning of the actual `notify` token (skip leading newline).
        var lineStart = start.lowerBound
        if text[lineStart] == "\n" { lineStart = text.index(after: lineStart) }
        // Find end of array. A `]` inside a quoted element (e.g. a JSON
        // argument another tool wrote) must not close the array.
        var i = closingBracket(in: text, after: start.upperBound) ?? text.endIndex
        if i < text.endIndex { i = text.index(after: i) }
        // Include trailing newline if present.
        if i < text.endIndex, text[i] == "\n" { i = text.index(after: i) }
        return lineStart..<i
    }

    /// Index of the `]` closing the array whose contents begin at `start`,
    /// skipping `]` characters inside quoted strings (honoring `\` escapes).
    private static func closingBracket(in text: String, after start: String.Index) -> String.Index? {
        var inQuote = false
        var escape = false
        var i = start
        while i < text.endIndex {
            let ch = text[i]
            if escape { escape = false }
            else if ch == "\\" { escape = true }
            else if ch == "\"" { inQuote.toggle() }
            else if ch == "]" && !inQuote { return i }
            i = text.index(after: i)
        }
        return nil
    }

    /// The string elements of the `notify = [...]` array, TOML-unescaped.
    public static func extractNotifyArray(from text: String) -> [String] {
        guard let r = notifyLineRange(in: text) else { return [] }
        let slice = String(text[r])
        guard let lb = slice.firstIndex(of: "["),
              let rb = closingBracket(in: slice, after: slice.index(after: lb)),
              lb < rb else { return [] }
        let inner = slice[slice.index(after: lb)..<rb]
        // Split on commas not inside quotes.
        var items: [String] = []
        var current = ""
        var inQuote = false
        var escape = false
        for ch in inner {
            if escape { current.append(ch); escape = false; continue }
            if ch == "\\" { current.append(ch); escape = true; continue }
            if ch == "\"" { inQuote.toggle(); current.append(ch); continue }
            if ch == "," && !inQuote {
                items.append(current); current = ""; continue
            }
            current.append(ch)
        }
        if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            items.append(current)
        }
        return items.compactMap(unquoteToml).filter { !$0.isEmpty }
    }

    private static func unquoteToml(_ raw: String) -> String? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.hasPrefix("\""), t.hasSuffix("\""), t.count >= 2 else { return nil }
        let inner = String(t.dropFirst().dropLast())
        return inner.replacingOccurrences(of: "\\\"", with: "\"")
                   .replacingOccurrences(of: "\\\\", with: "\\")
    }
}
