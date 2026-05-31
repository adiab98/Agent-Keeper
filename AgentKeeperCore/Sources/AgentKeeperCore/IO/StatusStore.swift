import Foundation

public struct StatusStore {
    public init() {}

    public func write(_ status: SessionStatus) throws {
        let url = AppPaths.statusDirectory.appendingPathComponent(status.statusFileName, isDirectory: false)
        try AtomicJSONWriter.write(status, to: url)
    }

    public func read(fileURL: URL) throws -> SessionStatus {
        try AtomicJSONWriter.read(SessionStatus.self, from: fileURL)
    }

    public func remove(_ id: String) {
        let url = AppPaths.statusDirectory.appendingPathComponent("\(id).json", isDirectory: false)
        try? FileManager.default.removeItem(at: url)
    }

    public func removeAll(matching predicate: (SessionStatus) -> Bool) {
        for status in readAll() where predicate(status) {
            remove(status.id)
        }
    }

    public func readAll() -> [SessionStatus] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: AppPaths.statusDirectory, includingPropertiesForKeys: nil) else {
            return []
        }
        var result: [SessionStatus] = []
        result.reserveCapacity(entries.count)
        for url in entries where url.pathExtension == "json" && !url.lastPathComponent.hasPrefix(".") {
            if let s = try? read(fileURL: url) {
                result.append(s)
            }
        }
        return result
    }
}
