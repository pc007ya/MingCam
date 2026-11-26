import Foundation
import AppKit
import Carbon

struct HotkeyCombo: Codable, Equatable, Hashable, Identifiable {
    var id: String { label }
    let keyCode: UInt32
    let carbonModifiers: UInt32
    let label: String

    // Common Presets for Snip (區域截圖)
    static let snipPresets: [HotkeyCombo] = [
        HotkeyCombo(keyCode: UInt32(kVK_ANSI_S), carbonModifiers: UInt32(cmdKey | shiftKey), label: "⇧⌘S (Shift+Cmd+S)"),
        HotkeyCombo(keyCode: UInt32(kVK_F1), carbonModifiers: 0, label: "F1 (Snipaste 經典)"),
        HotkeyCombo(keyCode: UInt32(kVK_ANSI_A), carbonModifiers: UInt32(cmdKey | shiftKey), label: "⇧⌘A (Shift+Cmd+A)"),
        HotkeyCombo(keyCode: UInt32(kVK_ANSI_A), carbonModifiers: UInt32(controlKey | optionKey), label: "⌃⌥A (Ctrl+Opt+A)"),
        HotkeyCombo(keyCode: UInt32(kVK_ANSI_X), carbonModifiers: UInt32(cmdKey | shiftKey), label: "⇧⌘X (Shift+Cmd+X)")
    ]

    // Common Presets for Pin (釘選貼圖)
    static let pinPresets: [HotkeyCombo] = [
        HotkeyCombo(keyCode: UInt32(kVK_ANSI_V), carbonModifiers: UInt32(cmdKey | shiftKey), label: "⇧⌘V (Shift+Cmd+V)"),
        HotkeyCombo(keyCode: UInt32(kVK_F3), carbonModifiers: 0, label: "F3 (Snipaste 經典)"),
        HotkeyCombo(keyCode: UInt32(kVK_ANSI_V), carbonModifiers: UInt32(controlKey | optionKey), label: "⌃⌥V (Ctrl+Opt+V)"),
        HotkeyCombo(keyCode: UInt32(kVK_ANSI_P), carbonModifiers: UInt32(cmdKey | shiftKey), label: "⇧⌘P (Shift+Cmd+P)")
    ]

    // Common Presets for Color Picker (取色放大鏡)
    static let colorPresets: [HotkeyCombo] = [
        HotkeyCombo(keyCode: UInt32(kVK_ANSI_C), carbonModifiers: UInt32(cmdKey | shiftKey), label: "⇧⌘C (Shift+Cmd+C)"),
        HotkeyCombo(keyCode: UInt32(kVK_F4), carbonModifiers: 0, label: "F4"),
        HotkeyCombo(keyCode: UInt32(kVK_ANSI_C), carbonModifiers: UInt32(controlKey | optionKey), label: "⌃⌥C (Ctrl+Opt+C)")
    ]

    // Common Presets for Record / Stop (開始/停止錄影)
    static let recordPresets: [HotkeyCombo] = [
        HotkeyCombo(keyCode: UInt32(kVK_ANSI_R), carbonModifiers: UInt32(cmdKey | shiftKey), label: "⇧⌘R (Shift+Cmd+R)"),
        HotkeyCombo(keyCode: UInt32(kVK_F2), carbonModifiers: 0, label: "F2"),
        HotkeyCombo(keyCode: UInt32(kVK_ANSI_R), carbonModifiers: UInt32(controlKey | optionKey), label: "⌃⌥R (Ctrl+Opt+R)")
    ]
}

@MainActor
final class GlobalHotkeyManager: ObservableObject {
    static let shared = GlobalHotkeyManager()

    @Published var isEnabled: Bool = true {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: "hk_enabled")
            reinstallHotkeys()
        }
    }

    @Published var keepAliveInBackground: Bool = true {
        didSet {
            UserDefaults.standard.set(keepAliveInBackground, forKey: "hk_keepAlive")
        }
    }

    @Published var snipHotkey: HotkeyCombo = HotkeyCombo.snipPresets[0] {
        didSet {
            saveCombo(snipHotkey, key: "hk_snip")
            reinstallHotkeys()
        }
    }

    @Published var alsoEnableF1F3: Bool = true {
        didSet {
            UserDefaults.standard.set(alsoEnableF1F3, forKey: "hk_f1f3")
            reinstallHotkeys()
        }
    }

    @Published var pinHotkey: HotkeyCombo = HotkeyCombo.pinPresets[0] {
        didSet {
            saveCombo(pinHotkey, key: "hk_pin")
            reinstallHotkeys()
        }
    }

    @Published var colorHotkey: HotkeyCombo = HotkeyCombo.colorPresets[0] {
        didSet {
            saveCombo(colorHotkey, key: "hk_color")
            reinstallHotkeys()
        }
    }

    @Published var recordHotkey: HotkeyCombo = HotkeyCombo.recordPresets[0] {
        didSet {
            saveCombo(recordHotkey, key: "hk_record")
            reinstallHotkeys()
        }
    }

    @Published var recordingTargetAction: String? = nil // "snip", "pin", "color", "record"

    var onSnipTriggered: (() -> Void)?
    var onPinTriggered: (() -> Void)?
    var onColorTriggered: (() -> Void)?
    var onRecordTriggered: (() -> Void)?
    var onEscapeTriggered: (() -> Void)?

    private var registeredRefs: [EventHotKeyRef?] = []
    private var escapeHotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var customKeyMonitor: Any?

    private init() {
        if UserDefaults.standard.object(forKey: "hk_enabled") != nil {
            self.isEnabled = UserDefaults.standard.bool(forKey: "hk_enabled")
        }
        if UserDefaults.standard.object(forKey: "hk_keepAlive") != nil {
            self.keepAliveInBackground = UserDefaults.standard.bool(forKey: "hk_keepAlive")
        }
        if UserDefaults.standard.object(forKey: "hk_f1f3") != nil {
            self.alsoEnableF1F3 = UserDefaults.standard.bool(forKey: "hk_f1f3")
        }
        if let s = loadCombo(key: "hk_snip") { self.snipHotkey = s }
        if let p = loadCombo(key: "hk_pin") { self.pinHotkey = p }
        if let c = loadCombo(key: "hk_color") { self.colorHotkey = c }
        if let r = loadCombo(key: "hk_record") { self.recordHotkey = r }

        installCarbonEventHandler()
        reinstallHotkeys()
    }

    func startCapturingCustomKey(for target: String) {
        stopCapturingCustomKey()
        recordingTargetAction = target
        customKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == 53 { // ESC cancels custom key recording
                self.stopCapturingCustomKey()
                return nil
            }
            let combo = self.comboFromNSEvent(event)
            switch target {
            case "snip": self.snipHotkey = combo
            case "pin": self.pinHotkey = combo
            case "color": self.colorHotkey = combo
            case "record": self.recordHotkey = combo
            default: break
            }
            self.stopCapturingCustomKey()
            return nil
        }
    }

    func stopCapturingCustomKey() {
        if let monitor = customKeyMonitor {
            NSEvent.removeMonitor(monitor)
            customKeyMonitor = nil
        }
        recordingTargetAction = nil
    }

    private func comboFromNSEvent(_ event: NSEvent) -> HotkeyCombo {
        var carbonMods: UInt32 = 0
        var modSymbols = ""
        let flags = event.modifierFlags
        if flags.contains(.control) {
            carbonMods |= UInt32(controlKey)
            modSymbols += "⌃"
        }
        if flags.contains(.option) {
            carbonMods |= UInt32(optionKey)
            modSymbols += "⌥"
        }
        if flags.contains(.shift) {
            carbonMods |= UInt32(shiftKey)
            modSymbols += "⇧"
        }
        if flags.contains(.command) {
            carbonMods |= UInt32(cmdKey)
            modSymbols += "⌘"
        }
        let keyName = keyCodeToString(event.keyCode, characters: event.charactersIgnoringModifiers)
        let label = "\(modSymbols)\(keyName)"
        return HotkeyCombo(keyCode: UInt32(event.keyCode), carbonModifiers: carbonMods, label: label)
    }

    private func keyCodeToString(_ keyCode: UInt16, characters: String?) -> String {
        switch Int(keyCode) {
        case kVK_F1: return "F1"
        case kVK_F2: return "F2"
        case kVK_F3: return "F3"
        case kVK_F4: return "F4"
        case kVK_F5: return "F5"
        case kVK_F6: return "F6"
        case kVK_F7: return "F7"
        case kVK_F8: return "F8"
        case kVK_F9: return "F9"
        case kVK_F10: return "F10"
        case kVK_F11: return "F11"
        case kVK_F12: return "F12"
        case kVK_Space: return "Space"
        default:
            if let chars = characters?.uppercased(), !chars.isEmpty {
                return chars
            }
            return "Key\(keyCode)"
        }
    }

    private func installCarbonEventHandler() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let handler: EventHandlerUPP = { _, eventRef, _ -> OSStatus in
            guard let eventRef else { return noErr }
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                eventRef,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )
            guard status == noErr else { return status }

            let id = hotKeyID.id
            Task { @MainActor in
                switch id {
                case 1, 101:
                    GlobalHotkeyManager.shared.onSnipTriggered?()
                case 2, 102:
                    GlobalHotkeyManager.shared.onPinTriggered?()
                case 3:
                    GlobalHotkeyManager.shared.onColorTriggered?()
                case 4:
                    GlobalHotkeyManager.shared.onRecordTriggered?()
                case 999:
                    GlobalHotkeyManager.shared.onEscapeTriggered?()
                default:
                    break
                }
            }
            return noErr
        }

        InstallEventHandler(
            GetApplicationEventTarget(),
            handler,
            1,
            &eventType,
            nil,
            &eventHandlerRef
        )
    }

    func setEscapeHotkeyActive(_ active: Bool) {
        if let escRef = escapeHotKeyRef {
            UnregisterEventHotKey(escRef)
            escapeHotKeyRef = nil
        }
        if active {
            let hotKeyID = EventHotKeyID(signature: OSType(0x4D43414D), id: 999)
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(
                UInt32(kVK_Escape),
                0,
                hotKeyID,
                GetApplicationEventTarget(),
                0,
                &ref
            )
            if status == noErr {
                escapeHotKeyRef = ref
            }
        }
    }

    func reinstallHotkeys() {
        for ref in registeredRefs {
            if let ref {
                UnregisterEventHotKey(ref)
            }
        }
        registeredRefs.removeAll()

        guard isEnabled else { return }

        registerSingle(id: 1, combo: snipHotkey)
        registerSingle(id: 2, combo: pinHotkey)
        registerSingle(id: 3, combo: colorHotkey)
        registerSingle(id: 4, combo: recordHotkey)

        // Also register F1 (Snip) & F3 (Pin) if enabled and not already chosen
        if alsoEnableF1F3 {
            if snipHotkey.keyCode != UInt32(kVK_F1) {
                registerSingle(id: 101, combo: HotkeyCombo(keyCode: UInt32(kVK_F1), carbonModifiers: 0, label: "F1"))
            }
            if pinHotkey.keyCode != UInt32(kVK_F3) {
                registerSingle(id: 102, combo: HotkeyCombo(keyCode: UInt32(kVK_F3), carbonModifiers: 0, label: "F3"))
            }
        }
    }

    private func registerSingle(id: UInt32, combo: HotkeyCombo) {
        let hotKeyID = EventHotKeyID(signature: OSType(0x4D43414D), id: id) // 'MCAM'
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            combo.keyCode,
            combo.carbonModifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        if status == noErr {
            registeredRefs.append(ref)
        }
    }

    private func saveCombo(_ combo: HotkeyCombo, key: String) {
        if let data = try? JSONEncoder().encode(combo) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    private func loadCombo(key: String) -> HotkeyCombo? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(HotkeyCombo.self, from: data)
    }
}
