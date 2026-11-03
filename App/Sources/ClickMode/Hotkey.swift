// The click-mode shortcut (⌥⌘K by default) through Carbon's `RegisterEventHotKey`. A registered hot key is
// delivered to the app as a Carbon event whichever app is frontmost, and needs no permission: it is not a key
// monitor or an event tap, and the app never sees any other key.
import AppKit
import Carbon.HIToolbox
import os

/// One system-wide hot key, registered on init until `unregister()`.
@MainActor
final class GlobalHotkey {
    /// False when the system refused the combination (another app may hold it).
    private(set) var isRegistered = false

    private let handler: @MainActor () -> Void
    private let identifier: UInt32
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    /// The +1 reference the Carbon handler's user data holds, released by `unregister()`, so the callback never
    /// sees a freed object.
    private var retainedSelf: Unmanaged<GlobalHotkey>?

    /// "PmLo", the signature of Pomelo's hot keys.
    private static let signature: OSType = 0x506D_4C6F
    private static var nextIdentifier: UInt32 = 1
    private static let log = Logger(subsystem: "io.github.pomelo-app.Pomelo", category: "click-mode")

    /// Registers `keyCode` with Carbon `modifiers` (`cmdKey`, `optionKey`, `controlKey`, `shiftKey`); `handler`
    /// runs on the main actor at each press.
    init(keyCode: UInt32 = UInt32(kVK_ANSI_K), modifiers: UInt32 = UInt32(optionKey | cmdKey),
         handler: @escaping @MainActor () -> Void) {
        self.handler = handler
        identifier = Self.nextIdentifier
        Self.nextIdentifier += 1

        let retained = Unmanaged.passRetained(self)
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var pressed = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &pressed)
            guard status == noErr else { return status }
            // The application event target delivers on the main thread.
            return MainActor.assumeIsolated {
                Unmanaged<GlobalHotkey>.fromOpaque(userData).takeUnretainedValue().pressed(pressed)
            }
        }, 1, &eventType, retained.toOpaque(), &handlerRef)
        guard installed == noErr else {
            retained.release()
            Self.log.error("InstallEventHandler failed: \(installed, privacy: .public)")
            return
        }
        retainedSelf = retained

        let hotKeyID = EventHotKeyID(signature: Self.signature, id: identifier)
        let registered = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
        guard registered == noErr else {
            Self.log.error("RegisterEventHotKey failed: \(registered, privacy: .public)")
            unregister()
            return
        }
        isRegistered = true
    }

    /// Removes the hot key and its handler. Safe to call more than once.
    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
        if let handlerRef { RemoveEventHandler(handlerRef) }
        handlerRef = nil
        isRegistered = false
        let retained = retainedSelf
        retainedSelf = nil
        retained?.release()
    }

    private func pressed(_ id: EventHotKeyID) -> OSStatus {
        guard id.signature == Self.signature, id.id == identifier else { return OSStatus(eventNotHandledErr) }
        handler()
        return noErr
    }
}
