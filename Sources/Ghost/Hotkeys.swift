// Global hotkeys (Carbon RegisterEventHotKey: works from any app, needs no Accessibility permission).
//
//   ⌃⌥G   summon the Ghost: put it on the Dock (it transmats in) or, if it is there, send it away
//   ⌃⌥⇧G  open or close the Ghost's panel (summons the Ghost first if it is away)

import AppKit
import Carbon.HIToolbox

@MainActor
final class Hotkeys {
    static let summonLabel = "⌃⌥G"
    static let panelLabel = "⌃⌥⇧G"

    private var refs: [EventHotKeyRef?] = []
    private var handler: EventHandlerRef?
    private var actions: [UInt32: () -> Void] = [:]

    init(summon: @escaping () -> Void, panel: @escaping () -> Void) {
        actions = [1: summon, 2: panel]
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let me = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, ctx in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard let ctx else { return noErr }
            let hk = Unmanaged<Hotkeys>.fromOpaque(ctx).takeUnretainedValue()
            let n = id.id
            MainActor.assumeIsolated { hk.actions[n]?() }
            return noErr
        }, 1, &spec, me, &handler)
        let sig = OSType(0x4748_5354) // "GHST"
        register(UInt32(kVK_ANSI_G), UInt32(controlKey | optionKey), EventHotKeyID(signature: sig, id: 1))
        register(UInt32(kVK_ANSI_G), UInt32(controlKey | optionKey | shiftKey), EventHotKeyID(signature: sig, id: 2))
    }

    private func register(_ key: UInt32, _ mods: UInt32, _ id: EventHotKeyID) {
        var ref: EventHotKeyRef?
        let st = RegisterEventHotKey(key, mods, id, GetApplicationEventTarget(), 0, &ref)
        if st != noErr { GhostLog.write("hotkey \(id.id) not registered (\(st))") }
        refs.append(ref)
    }
}
