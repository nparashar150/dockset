import AppKit
import Carbon.HIToolbox

/// System-wide key combinations that switch layouts.
///
/// Carbon's `RegisterEventHotKey` rather than an event monitor: a global
/// monitor sees keys only with Accessibility granted and cannot stop the key
/// reaching the frontmost app, while a registered hot key needs no permission
/// and is consumed. It is still the API every shortcut utility uses.
@MainActor
final class ProfileHotkeys {
    static let shared = ProfileHotkeys()

    /// Called with the profile whose combination was pressed.
    var onFire: ((UUID) -> Void)?

    private var registered: [EventHotKeyRef] = []
    /// Carbon identifies a hot key by a number; this maps it back.
    private var profiles: [UInt32: UUID] = [:]
    private var handlerInstalled = false
    /// The last set applied, so an unrelated state change does not tear down
    /// and re-register every key.
    private var current: [UUID: KeyCombo] = [:]

    private init() {}

    /// Replaces every registration with `bindings`.
    ///
    /// A combination another app already holds fails to register and is
    /// skipped, so the rest still work.
    func apply(_ bindings: [UUID: KeyCombo]) {
        guard bindings != current else { return }
        current = bindings
        guard !paused else { return }
        register(bindings)
    }

    /// Off while a shortcut is being recorded, or pressing a combination a
    /// layout already has would switch layouts instead of being recorded.
    var paused = false {
        didSet {
            guard paused != oldValue else { return }
            register(paused ? [:] : current)
        }
    }

    private func register(_ bindings: [UUID: KeyCombo]) {
        installHandler()
        registered.forEach { UnregisterEventHotKey($0) }
        registered.removeAll()
        profiles.removeAll()

        for (number, (profile, combo)) in bindings.enumerated() {
            let id = EventHotKeyID(signature: Self.signature, id: UInt32(number + 1))
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(combo.keyCode, combo.modifiers, id,
                                             GetApplicationEventTarget(), 0, &ref)
            guard status == noErr, let ref else { continue }
            registered.append(ref)
            profiles[id.id] = profile
        }
    }

    fileprivate func fire(_ number: UInt32) {
        guard let profile = profiles[number] else { return }
        onFire?(profile)
    }

    /// 'DKPS', so our hot keys are told apart from anyone else's in this process.
    private static let signature: OSType = 0x444B_5053

    private func installHandler() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard status == noErr, id.signature == ProfileHotkeys.signature else {
                return OSStatus(eventNotHandledErr)
            }
            // Delivered on the main thread: the handler is on the
            // application target, which the main run loop services.
            MainActor.assumeIsolated { ProfileHotkeys.shared.fire(id.id) }
            return noErr
        }, 1, &spec, nil, nil)
    }
}

extension KeyCombo {
    /// From a key press in the recorder. Nil without at least two modifiers,
    /// which is what keeps a layout switch from stealing an app's own
    /// shortcut such as Command-1.
    init?(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var carbon: UInt32 = 0
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
        guard carbon.nonzeroBitCount >= 2 else { return nil }
        self.init(keyCode: UInt32(event.keyCode), modifiers: carbon)
    }

    /// "⌃⌥1", in the order macOS menus print modifiers.
    var display: String {
        var text = ""
        if modifiers & UInt32(controlKey) != 0 { text += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { text += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { text += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { text += "⌘" }
        return text + Self.keyName(keyCode)
    }

    /// The key's name on the current keyboard layout, so an AZERTY user sees
    /// the letter printed on their key rather than the US one.
    private static func keyName(_ code: UInt32) -> String {
        let named: [Int: String] = [
            kVK_Return: "↩", kVK_Tab: "⇥", kVK_Space: "Space", kVK_Delete: "⌫",
            kVK_ForwardDelete: "⌦", kVK_LeftArrow: "←", kVK_RightArrow: "→",
            kVK_UpArrow: "↑", kVK_DownArrow: "↓", kVK_Home: "↖", kVK_End: "↘",
            kVK_PageUp: "⇞", kVK_PageDown: "⇟",
            kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5",
            kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10",
            kVK_F11: "F11", kVK_F12: "F12",
        ]
        if let name = named[Int(code)] { return name }
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return "?" }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        var dead: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length = 0
        let status = data.withUnsafeBytes { raw -> OSStatus in
            guard let layout = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return -1 }
            return UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDisplay), 0,
                                  UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                                  &dead, chars.count, &length, &chars)
        }
        guard status == noErr, length > 0 else { return "?" }
        return String(utf16CodeUnits: chars, count: length).uppercased()
    }
}
