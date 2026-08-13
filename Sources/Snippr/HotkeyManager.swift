import AppKit
import Carbon.HIToolbox

/// Global hotkeys via Carbon RegisterEventHotKey (no Accessibility permission needed).
final class HotkeyManager {
    static let shared = HotkeyManager()

    var handler: (@MainActor (HotkeyAction) -> Void)?
    /// Receives Carbon hotkey ids not owned by HotkeyManager (e.g. the
    /// temporary Esc hotkey during scrolling capture).
    var auxHandler: (@MainActor (UInt32) -> Void)?

    private var hotkeyRefs: [UInt32: EventHotKeyRef] = [:]
    private var idToAction: [UInt32: HotkeyAction] = [:]
    private var nextID: UInt32 = 1
    private var eventHandlerRef: EventHandlerRef?

    func start() {
        installEventHandler()
        reloadAll()
    }

    func reloadAll() {
        for (_, ref) in hotkeyRefs { UnregisterEventHotKey(ref) }
        hotkeyRefs.removeAll()
        idToAction.removeAll()
        for action in HotkeyAction.allCases {
            if let combo = Settings.shared.combo(for: action) {
                register(combo: combo, action: action)
            }
        }
    }

    private func register(combo: KeyCombo, action: HotkeyAction) {
        let id = nextID
        nextID += 1
        let hotKeyID = EventHotKeyID(signature: OSType(0x534E5052) /* 'SNPR' */, id: id)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            combo.keyCode, combo.modifiers, hotKeyID,
            GetApplicationEventTarget(), 0, &ref
        )
        if status == noErr, let ref {
            hotkeyRefs[id] = ref
            idToAction[id] = action
        } else {
            NSLog("Snippr: failed to register hotkey \(combo.display) for \(action.rawValue) (status \(status))")
        }
    }

    private func installEventHandler() {
        guard eventHandlerRef == nil else { return }
        var eventSpec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let callback: EventHandlerUPP = { _, event, userData in
            guard let event, let userData else { return noErr }
            var hotKeyID = EventHotKeyID()
            let err = GetEventParameter(
                event, EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID), nil,
                MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID
            )
            if err == noErr {
                let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
                manager.fire(id: hotKeyID.id)
            }
            return noErr
        }
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), callback, 1, &eventSpec, selfPtr, &eventHandlerRef)
    }

    private func fire(id: UInt32) {
        if let action = idToAction[id] {
            Task { @MainActor [weak self] in
                self?.handler?(action)
            }
        } else {
            Task { @MainActor [weak self] in
                self?.auxHandler?(id)
            }
        }
    }
}
