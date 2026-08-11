import CoreServices
import Foundation

public final class SessionLibraryMonitor: @unchecked Sendable {
    public typealias ChangeHandler = @Sendable (_ requiresFullScan: Bool) -> Void

    private let queue = DispatchQueue(
        label: "com.localfirst.Scribe.session-library-monitor",
        qos: .utility
    )
    private var stream: FSEventStreamRef?
    private var callbackBox: CallbackBox?

    public init() {}

    deinit {
        stop()
    }

    public func start(
        root: URL,
        latency: TimeInterval = 0.25,
        onChange: @escaping ChangeHandler
    ) throws {
        stop()
        let box = CallbackBox(handler: onChange)
        callbackBox = box
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(box).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = {
            _, info, eventCount, _, eventFlags, _ in
            guard let info else { return }
            let box = Unmanaged<CallbackBox>
                .fromOpaque(info)
                .takeUnretainedValue()
            var requiresFullScan = false
            for index in 0..<Int(eventCount) {
                let flags = eventFlags[index]
                let fullScanFlags =
                    FSEventStreamEventFlags(
                        kFSEventStreamEventFlagMustScanSubDirs
                    )
                    | FSEventStreamEventFlags(
                        kFSEventStreamEventFlagUserDropped
                    )
                    | FSEventStreamEventFlags(
                        kFSEventStreamEventFlagKernelDropped
                    )
                    | FSEventStreamEventFlags(
                        kFSEventStreamEventFlagRootChanged
                    )
                if flags & fullScanFlags != 0 {
                    requiresFullScan = true
                    break
                }
            }
            box.handler(requiresFullScan)
        }
        guard let stream = FSEventStreamCreate(
            nil,
            callback,
            &context,
            [root.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents)
                | FSEventStreamCreateFlags(kFSEventStreamCreateFlagWatchRoot)
        ) else {
            callbackBox = nil
            throw SessionLibraryMonitorError.couldNotCreateStream(root)
        }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
            callbackBox = nil
            throw SessionLibraryMonitorError.couldNotStartStream(root)
        }
    }

    public func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
        callbackBox = nil
    }
}

private final class CallbackBox: @unchecked Sendable {
    let handler: SessionLibraryMonitor.ChangeHandler

    init(handler: @escaping SessionLibraryMonitor.ChangeHandler) {
        self.handler = handler
    }
}

public enum SessionLibraryMonitorError: Error, LocalizedError {
    case couldNotCreateStream(URL)
    case couldNotStartStream(URL)

    public var errorDescription: String? {
        switch self {
        case let .couldNotCreateStream(url):
            "Scribe could not watch the session folder at \(url.path)."
        case let .couldNotStartStream(url):
            "Scribe could not start watching the session folder at \(url.path)."
        }
    }
}
