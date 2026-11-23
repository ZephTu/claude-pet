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
    /// ⌃⌥⌘ plus a letter. Three modifiers on purpose: two-modifier chords are
    /// where apps and the system already live, and these have to be safe to
    /// enable without auditing what else is installed.
    static let defaultModifiers = UInt32(controlKey | optionKey | cmdKey)
    /// ⌃⌥⌘J jumps to the session waiting longest. nonisolated so the menu can
    /// title itself without hopping actors.
    nonisolated static let displayName = "⌃⌥⌘J"
    /// ⌃⌥⌘N opens the quick-note panel.
    nonisolated static let noteDisplayName = "⌃⌥⌘N"
    static let noteKeyCode = UInt32(kVK_ANSI_N)

    let keyCode: UInt32
    let name: String
    private var ref: EventHotKeyRef?
    private let action: () -> Void
    private let slot: UInt32

    /// Carbon hands the callback a raw pointer, so the instances have to be
    /// reachable from a plain C function: by the id each registers with.
    private static var live: [UInt32: HotKey] = [:]
    private static var nextSlot: UInt32 = 1
    /// One handler for every shortcut, installed with the first one.
    private static var handler: EventHandlerRef?

    init(keyCode: UInt32 = UInt32(kVK_ANSI_J), name: String = HotKey.displayName, action: @escaping () -> Void) {
        self.keyCode = keyCode
        self.name = name
        self.action = action
        slot = Self.nextSlot
        Self.nextSlot += 1
    }

    var isRegistered: Bool { ref != nil }

    @discardableResult
    func register() -> Bool {
        guard ref == nil else { return true }
        Self.installHandler()
        let id = EventHotKeyID(signature: Self.signature, id: slot)
        let status = RegisterEventHotKey(keyCode, Self.defaultModifiers, id,
                                         GetEventDispatcherTarget(), 0, &ref)
        if status != noErr {
            // Another app already owns the chord. Not an error worth a dialog —
            // the feature is optional — but it must not look like it worked.
            NSLog("ClaudePet: could not register \(name) (status \(status))")
            ref = nil
            return false
        }
        Self.live[slot] = self
        return true
    }

    func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
        Self.live[slot] = nil
    }

    private static func installHandler() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetEventDispatcherTarget(), { _, event, _ -> OSStatus in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard id.signature == HotKey.signature else { return noErr }
            let slot = id.id
            // The Carbon callback is not isolated; the work it triggers touches
            // AppKit, so it is hopped onto the main actor explicitly.
            DispatchQueue.main.async {
                MainActor.assumeIsolated { HotKey.live[slot]?.action() }
            }
            return noErr
        }, 1, &spec, nil, &handler)
    }

    private nonisolated static let signature: OSType = {
        // 'CPet' as a four-char code.
        let chars = Array("CPet".utf8)
        return chars.reduce(OSType(0)) { ($0 << 8) | OSType($1) }
    }()
}
