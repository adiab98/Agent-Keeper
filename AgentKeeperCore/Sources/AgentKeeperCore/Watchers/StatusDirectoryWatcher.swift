import Foundation
import CoreServices

/// Watches the status directory for file changes using FSEventStreamCreate.
///
/// FSEventStream is the macOS-native API for directory-tree change notifications
/// and is more reliable under load than `DispatchSourceFileSystemObject` on a
/// directory fd (the latter can drop events when multiple files churn at once,
/// which is exactly what happens when several producers write status files
/// simultaneously). Public API is identical to the previous implementation —
/// caller passes a directory URL and a callback.
public final class StatusDirectoryWatcher {
    private let url: URL
    private let onChange: () -> Void
    private var stream: FSEventStreamRef?

    public init(directory: URL, onChange: @escaping () -> Void) {
        self.url = directory
        self.onChange = onChange
    }

    public func start() {
        AppPaths.ensureDirectory(url)
        let paths = [url.path] as CFArray
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let flags: FSEventStreamCreateFlags = UInt32(
            kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagNoDefer
                | kFSEventStreamCreateFlagUseCFTypes
        )
        let latency: CFTimeInterval = 0.1 // 100ms coalescing
        let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            { _, info, _, _, _, _ in
                guard let info else { return }
                let watcher = Unmanaged<StatusDirectoryWatcher>.fromOpaque(info).takeUnretainedValue()
                watcher.onChange()
            },
            &context,
            paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            flags
        )
        guard let stream else { return }
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.global(qos: .utility))
        FSEventStreamStart(stream)
        self.stream = stream

        // Fire once at start so subscribers can populate immediately.
        onChange()
    }

    public func stop() {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
    }

    deinit { stop() }
}
