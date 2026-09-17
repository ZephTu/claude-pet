import AppKit
import Carbon.HIToolbox

/// A system-wide shortcut, registered through Carbon.
///
/// Carbon rather than `NSEvent.addGlobalMonitorForEvents`, and the reason is
/// the whole point: a global NSEvent monitor needs Accessibility permission,
/// which means a scary system prompt and a pet that silently stops working if
/// the user says no. `RegisterEventHotKey` needs no permission at all.
///
/// Off by default. A desktop toy that claims a system-wide chord the first time
/// it runs is taking something that was not offered.
@MainActor
final class HotKey {
    /// ⌃⌥⌘J. Three modifiers on purpose: two-modifier chords are where apps
    /// and the system already live, and this one has to be safe to enable
    /// without auditing what else is installed.
    static let defaultKeyCode = UInt32(kVK_ANSI_J)
    static let defaultModifiers = UInt32(controlKey | optionKey | cmdKey)
    /// nonisolated so the menu can title itself without hopping actors.
    nonisolated static let displayName = "⌃⌥⌘J"

    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: () -> Void

    /// Carbon hands the callback a raw pointer, so the instance has to be
    /// reachable from a plain C function. One shortcut, one slot.
    private static var current: HotKey?

    init(action: @escaping () -> Void) {
        self.action = action
    }

    var isRegistered: Bool { ref != nil }

    @discardableResult
    func register() -> Bool {
        guard ref == nil else { return true }
        Self.current = self

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetEventDispatcherTarget(), { _, event, _ -> OSStatus in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard id.signature == HotKey.signature else { return noErr }
            // The Carbon callback is not isolated; the work it triggers touches
            // AppKit, so it is hopped onto the main actor explicitly.
            DispatchQueue.main.async {
                MainActor.assumeIsolated { HotKey.current?.action() }
            }
            return noErr
        }, 1, &spec, nil, &handler)

        let id = EventHotKeyID(signature: Self.signature, id: 1)
        let status = RegisterEventHotKey(Self.defaultKeyCode, Self.defaultModifiers, id,
                                         GetEventDispatcherTarget(), 0, &ref)
        if status != noErr {
            // Another app already owns the chord. Not an error worth a dialog —
            // the feature is optional — but it must not look like it worked.
            NSLog("ClaudePet: could not register \(Self.displayName) (status \(status))")
            ref = nil
            return false
        }
        return true
    }

    func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
        if let handler { RemoveEventHandler(handler) }
        handler = nil
        if Self.current === self { Self.current = nil }
    }

    private static let signature: OSType = {
        // 'CPet' as a four-char code.
        let chars = Array("CPet".utf8)
        return chars.reduce(OSType(0)) { ($0 << 8) | OSType($1) }
    }()
}
