//
//  HotKeyManager.swift
//  ClipVault
//
//  Registers the global ⇧⌘7 hotkey using Carbon's RegisterEventHotKey.
//  Works in sandboxed apps and requires no Accessibility permission.
//

import AppKit
import Carbon.HIToolbox

/// Manages the app's single global hotkey (⇧⌘7 → open clipboard history).
final class HotKeyManager {
    static let shared = HotKeyManager()
    private init() {}

    private var onHotKey: (() -> Void)?
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?

    private static let signature: OSType = {
        var result: OSType = 0
        for byte in "CLPV".utf8 { result = (result << 8) + OSType(byte) }
        return result
    }()

    private let hotKeyID = EventHotKeyID(signature: HotKeyManager.signature, id: 1)

    /// Registers ⇧⌘7 as a global hotkey. Repeated calls are ignored.
    func register(onHotKey: @escaping () -> Void) {
        guard hotKeyRef == nil else {
            AppLogger.hotkeys.debug("Hotkey already registered; ignoring duplicate register call")
            return
        }

        self.onHotKey = onHotKey

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        // The handler is a C function pointer and cannot capture context,
        // so self is passed through userData (safe: the singleton never deallocates).
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData -> OSStatus in
                guard let event, let userData else { return noErr }

                var pressedID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &pressedID
                )
                guard status == noErr else { return status }

                let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
                if pressedID.signature == manager.hotKeyID.signature,
                   pressedID.id == manager.hotKeyID.id {
                    DispatchQueue.main.async {
                        manager.onHotKey?()
                    }
                }
                return noErr
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandlerRef
        )

        guard installStatus == noErr else {
            AppLogger.hotkeys.error("Failed to install hotkey event handler (status: \(installStatus))")
            return
        }

        let registerStatus = RegisterEventHotKey(
            UInt32(kVK_ANSI_7),
            UInt32(cmdKey | shiftKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        if registerStatus == noErr {
            AppLogger.hotkeys.info("Registered global hotkey ⇧⌘7")
        } else {
            AppLogger.hotkeys.error("Failed to register global hotkey ⇧⌘7 (status: \(registerStatus))")
            if let eventHandlerRef {
                RemoveEventHandler(eventHandlerRef)
                self.eventHandlerRef = nil
            }
        }
    }

    /// Unregisters the hotkey and removes the event handler.
    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
            self.eventHandlerRef = nil
        }
        onHotKey = nil
        AppLogger.hotkeys.info("Unregistered global hotkey")
    }
}
