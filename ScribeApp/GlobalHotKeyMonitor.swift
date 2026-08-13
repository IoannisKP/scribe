import Carbon.HIToolbox
import Foundation

enum GlobalHotKeyMonitorError: Error, LocalizedError {
    case handlerRegistrationFailed(OSStatus)
    case hotKeyRegistrationFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case let .handlerRegistrationFailed(status):
            "The global shortcut handler could not start (\(status))."
        case let .hotKeyRegistrationFailed(status):
            "The global shortcut could not be registered (\(status))."
        }
    }
}

/// Carbon hot keys are delivered to the application even when none of its
/// windows is focused. They do not require Accessibility permission.
final class GlobalHotKeyMonitor: @unchecked Sendable {
    static let recordingPinID: UInt32 = 1

    private static let signature: OSType = 0x5363_7262 // Scrb

    private let action: @MainActor @Sendable () -> Void
    private var eventHandler: EventHandlerRef?
    private var hotKey: EventHotKeyRef?

    init(action: @escaping @MainActor @Sendable () -> Void) {
        self.action = action
    }

    deinit {
        stop()
    }

    func start() throws {
        guard hotKey == nil else { return }
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let userData = Unmanaged.passUnretained(self).toOpaque()
        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let event, let userData else {
                    return OSStatus(eventNotHandledErr)
                }
                let monitor = Unmanaged<GlobalHotKeyMonitor>
                    .fromOpaque(userData)
                    .takeUnretainedValue()
                return monitor.handle(event)
            },
            1,
            &eventType,
            userData,
            &eventHandler
        )
        guard handlerStatus == noErr else {
            throw GlobalHotKeyMonitorError.handlerRegistrationFailed(
                handlerStatus
            )
        }

        let identifier = EventHotKeyID(
            signature: Self.signature,
            id: Self.recordingPinID
        )
        let registrationStatus = RegisterEventHotKey(
            UInt32(kVK_ANSI_K),
            UInt32(cmdKey | shiftKey),
            identifier,
            GetApplicationEventTarget(),
            0,
            &hotKey
        )
        guard registrationStatus == noErr else {
            stop()
            throw GlobalHotKeyMonitorError.hotKeyRegistrationFailed(
                registrationStatus
            )
        }
    }

    func stop() {
        if let hotKey {
            UnregisterEventHotKey(hotKey)
            self.hotKey = nil
        }
        if let eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
    }

    private func handle(_ event: EventRef) -> OSStatus {
        var identifier = EventHotKeyID()
        let status = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &identifier
        )
        guard
            status == noErr,
            identifier.signature == Self.signature,
            identifier.id == Self.recordingPinID
        else {
            return OSStatus(eventNotHandledErr)
        }
        let action = action
        Task { @MainActor in
            action()
        }
        return noErr
    }
}
