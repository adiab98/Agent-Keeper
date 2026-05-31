import Foundation

public enum AtomicJSONWriter {
    public static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .millisecondsSince1970
        return e
    }()

    public static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .millisecondsSince1970
        return d
    }()

    public enum WriteError: Error {
        case encodingFailed
        case ioFailed(String)
    }

    public static func write<T: Encodable>(_ value: T, to url: URL) throws {
        let data: Data
        do {
            data = try encoder.encode(value)
        } catch {
            throw WriteError.encodingFailed
        }
        try writeRaw(data, to: url)
    }

    public static func writeRaw(_ data: Data, to url: URL) throws {
        let dir = url.deletingLastPathComponent()
        AppPaths.ensureDirectory(dir)
        let tmpName = ".\(url.lastPathComponent).tmp.\(ProcessInfo.processInfo.processIdentifier).\(UInt64.random(in: 0...UInt64.max))"
        let tmp = dir.appendingPathComponent(tmpName, isDirectory: false)
        let fm = FileManager.default

        guard fm.createFile(atPath: tmp.path, contents: data, attributes: nil) else {
            throw WriteError.ioFailed("createFile failed for \(tmp.path)")
        }

        let fd = open(tmp.path, O_WRONLY)
        if fd >= 0 {
            _ = fsync(fd)
            close(fd)
        }

        if rename(tmp.path, url.path) != 0 {
            try? fm.removeItem(at: tmp)
            throw WriteError.ioFailed("rename failed: errno=\(errno)")
        }
    }

    public static func read<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        let data = try Data(contentsOf: url)
        return try decoder.decode(type, from: data)
    }
}
