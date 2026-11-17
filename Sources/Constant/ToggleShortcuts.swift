import AppKit
import Carbon.HIToolbox

/// Something a hotkey or MIDI command can do. The raw value is also the Carbon hotkey ID.
enum ShortcutAction: UInt32, CaseIterable, Sendable {
    case panel = 1  // show/hide the plugin panel
    case mute = 2   // mute/unmute the instrument

    /// The panel keeps the original defaults keys so existing shortcuts survive the update.
    func defaultsKey(_ base: String) -> String {
        self == .panel ? base : base + "Mute"
    }
}

/// Watches incoming MIDI for the messages bound to shortcut actions. Runs on the CoreMIDI thread.
final class MIDITrigger: @unchecked Sendable {
    struct Binding: Equatable, Sendable {
        let status: UInt8  // message kind + channel
        let data1: UInt8   // note, controller or program number
    }

    private let lock = NSLock()
    private var bindings: [ShortcutAction: Binding] = [:]
    private var learning: ShortcutAction?
    private var onTrigger: (@Sendable (ShortcutAction) -> Void)?
    private var onLearned: (@Sendable (ShortcutAction, Binding) -> Void)?

    func setCallbacks(
        onTrigger: @escaping @Sendable (ShortcutAction) -> Void,
        onLearned: @escaping @Sendable (ShortcutAction, Binding) -> Void
    ) {
        lock.lock()
        self.onTrigger = onTrigger
        self.onLearned = onLearned
        lock.unlock()
    }

    func setBinding(_ newBinding: Binding?, for action: ShortcutAction) {
        lock.lock()
        bindings[action] = newBinding
        lock.unlock()
    }

    func setLearning(_ action: ShortcutAction?) {
        lock.lock()
        learning = action
        lock.unlock()
    }

    /// Returns true when the message belongs to a trigger and must not reach the instrument.
    func handle(status: UInt8, data1: UInt8, data2: UInt8) -> Bool {
        let kind = status & 0xF0
        // A press: note on, controller above zero, or program change.
        let isPress = (kind == 0x90 && data2 > 0) || (kind == 0xB0 && data2 > 0) || kind == 0xC0

        lock.lock()
        defer { lock.unlock() }

        if let action = learning {
            guard isPress else { return false }
            let learned = Binding(status: status, data1: data1)
            bindings[action] = learned
            learning = nil
            onLearned?(action, learned)
            return true
        }

        for (action, binding) in bindings where data1 == binding.data1 {
            // Also swallow the note off that follows a bound note on.
            let isNoteOff = binding.status & 0xF0 == 0x90 && status == binding.status - 0x10
            guard status == binding.status || isNoteOff else { continue }
            if isPress { onTrigger?(action) }
            return true
        }
        return false
    }
}

struct HotKey: Equatable {
    let keyCode: UInt32
    let modifiers: UInt32  // Carbon modifier mask
    let display: String
}

/// Global hotkeys and MIDI commands for the shortcut actions.
@MainActor
final class ToggleShortcuts: ObservableObject {
    @Published private(set) var hotKeys: [ShortcutAction: HotKey] = [:]
    @Published private(set) var hotKeyErrors: [ShortcutAction: String] = [:]
    /// The action whose hotkey is being recorded, if any.
    @Published private(set) var recordingHotKey: ShortcutAction?
    @Published private(set) var midiBindings: [ShortcutAction: MIDITrigger.Binding] = [:]
    /// The action whose MIDI command is being learned, if any.
    @Published private(set) var learningMIDI: ShortcutAction?

    var isRecordingHotKey: Bool { recordingHotKey != nil }

    nonisolated let midiTrigger = MIDITrigger()

    /// Called on the main thread when a shortcut fires.
    var onTrigger: ((ShortcutAction) -> Void)?

    private var hotKeyRefs: [ShortcutAction: EventHotKeyRef] = [:]
    private var keyMonitor: Any?

    private static let keyCodeKey = "hotKeyCode"
    private static let modifiersKey = "hotKeyModifiers"
    private static let displayKey = "hotKeyDisplay"
    private static let midiStatusKey = "midiTriggerStatus"
    private static let midiData1Key = "midiTriggerData1"

    init() {
        let defaults = UserDefaults.standard
        for action in ShortcutAction.allCases {
            if let display = defaults.string(forKey: action.defaultsKey(Self.displayKey)) {
                hotKeys[action] = HotKey(
                    keyCode: UInt32(defaults.integer(forKey: action.defaultsKey(Self.keyCodeKey))),
                    modifiers: UInt32(defaults.integer(forKey: action.defaultsKey(Self.modifiersKey))),
                    display: display)
            }
            if defaults.object(forKey: action.defaultsKey(Self.midiStatusKey)) != nil {
                let binding = MIDITrigger.Binding(
                    status: UInt8(truncatingIfNeeded:
                        defaults.integer(forKey: action.defaultsKey(Self.midiStatusKey))),
                    data1: UInt8(truncatingIfNeeded:
                        defaults.integer(forKey: action.defaultsKey(Self.midiData1Key))))
                midiBindings[action] = binding
                midiTrigger.setBinding(binding, for: action)
            }
        }

        midiTrigger.setCallbacks(
            onTrigger: { [weak self] action in
                DispatchQueue.main.async { self?.onTrigger?(action) }
            },
            onLearned: { [weak self] action, binding in
                DispatchQueue.main.async { self?.midiLearned(binding, for: action) }
            })

        installHotKeyHandler()
        registerHotKeys()
    }

    /// Stops any hotkey recording or MIDI learn in progress.
    func cancelCapture() {
        if recordingHotKey != nil {
            stopKeyMonitor()
            recordingHotKey = nil
            registerHotKeys()
        }
        if learningMIDI != nil {
            learningMIDI = nil
            midiTrigger.setLearning(nil)
        }
    }

    // MARK: - Hotkey

    func toggleHotKeyRecording(for action: ShortcutAction) {
        if recordingHotKey == action {
            cancelCapture()
            return
        }
        cancelCapture()
        unregisterHotKeys()  // so pressing a current shortcut records it instead of firing
        hotKeyErrors[action] = nil
        recordingHotKey = action

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let keyCode = event.keyCode
            let flags = event.modifierFlags
            let characters = event.charactersIgnoringModifiers
            DispatchQueue.main.async {
                self?.record(keyCode: keyCode, flags: flags, characters: characters)
            }
            return nil
        }
    }

    func clearHotKey(for action: ShortcutAction) {
        cancelCapture()
        setHotKey(nil, for: action)
    }

    private func record(keyCode: UInt16, flags: NSEvent.ModifierFlags, characters: String?) {
        guard let action = recordingHotKey else { return }
        let modifiers = flags.intersection([.command, .option, .control, .shift])

        if keyCode == UInt16(kVK_Escape), modifiers.isEmpty {
            cancelCapture()
            return
        }
        // Plain keys would block normal typing everywhere, so require a modifier or an F-key.
        let isFunctionKey = Self.functionKeys[keyCode] != nil
        guard isFunctionKey || !modifiers.intersection([.command, .option, .control]).isEmpty else {
            NSSound.beep()
            return
        }

        var carbon: UInt32 = 0
        var display = ""
        if modifiers.contains(.control) { carbon |= UInt32(controlKey); display += "⌃" }
        if modifiers.contains(.option) { carbon |= UInt32(optionKey); display += "⌥" }
        if modifiers.contains(.shift) { carbon |= UInt32(shiftKey); display += "⇧" }
        if modifiers.contains(.command) { carbon |= UInt32(cmdKey); display += "⌘" }
        display += Self.functionKeys[keyCode] ?? Self.namedKeys[keyCode]
            ?? characters?.uppercased() ?? "Key \(keyCode)"

        stopKeyMonitor()
        recordingHotKey = nil
        let hotKey = HotKey(keyCode: UInt32(keyCode), modifiers: carbon, display: display)
        // One key combination can only do one thing.
        for other in ShortcutAction.allCases where other != action {
            if let existing = hotKeys[other],
               existing.keyCode == hotKey.keyCode, existing.modifiers == hotKey.modifiers {
                setHotKey(nil, for: other)
            }
        }
        setHotKey(hotKey, for: action)
    }

    private func setHotKey(_ newHotKey: HotKey?, for action: ShortcutAction) {
        unregisterHotKeys()
        hotKeys[action] = newHotKey
        hotKeyErrors[action] = nil

        let defaults = UserDefaults.standard
        if let newHotKey {
            defaults.set(Int(newHotKey.keyCode), forKey: action.defaultsKey(Self.keyCodeKey))
            defaults.set(Int(newHotKey.modifiers), forKey: action.defaultsKey(Self.modifiersKey))
            defaults.set(newHotKey.display, forKey: action.defaultsKey(Self.displayKey))
        } else {
            defaults.removeObject(forKey: action.defaultsKey(Self.keyCodeKey))
            defaults.removeObject(forKey: action.defaultsKey(Self.modifiersKey))
            defaults.removeObject(forKey: action.defaultsKey(Self.displayKey))
        }
        registerHotKeys()
    }

    private func stopKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    private func installHotKeyHandler() {
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let event, let userData else { return noErr }
                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event, EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID), nil,
                    MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
                guard status == noErr, let action = ShortcutAction(rawValue: hotKeyID.id) else {
                    return noErr
                }
                let shortcuts = Unmanaged<ToggleShortcuts>.fromOpaque(userData).takeUnretainedValue()
                DispatchQueue.main.async { shortcuts.onTrigger?(action) }
                return noErr
            },
            1, &spec, Unmanaged.passUnretained(self).toOpaque(), nil)
    }

    private func registerHotKeys() {
        for (action, hotKey) in hotKeys where hotKeyRefs[action] == nil {
            let id = EventHotKeyID(signature: OSType(0x434E_5354), id: action.rawValue)  // 'CNST'
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(
                hotKey.keyCode, hotKey.modifiers, id, GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref {
                hotKeyRefs[action] = ref
            } else {
                hotKeyErrors[action] = "This shortcut is already used by another app."
            }
        }
    }

    private func unregisterHotKeys() {
        for ref in hotKeyRefs.values { UnregisterEventHotKey(ref) }
        hotKeyRefs = [:]
    }

    // MARK: - MIDI

    func midiDescription(for action: ShortcutAction) -> String? {
        guard let binding = midiBindings[action] else { return nil }
        let channel = Int(binding.status & 0x0F) + 1
        switch binding.status & 0xF0 {
        case 0x90: return "Note \(binding.data1), channel \(channel)"
        case 0xB0: return "CC \(binding.data1), channel \(channel)"
        default: return "Program \(binding.data1), channel \(channel)"
        }
    }

    func toggleMIDILearn(for action: ShortcutAction) {
        if learningMIDI == action {
            cancelCapture()
            return
        }
        cancelCapture()
        learningMIDI = action
        midiTrigger.setLearning(action)
    }

    func clearMIDI(for action: ShortcutAction) {
        cancelCapture()
        setMIDIBinding(nil, for: action)
    }

    private func midiLearned(_ binding: MIDITrigger.Binding, for action: ShortcutAction) {
        learningMIDI = nil
        // One MIDI message can only do one thing.
        for other in ShortcutAction.allCases where other != action && midiBindings[other] == binding {
            setMIDIBinding(nil, for: other)
        }
        setMIDIBinding(binding, for: action)
    }

    private func setMIDIBinding(_ binding: MIDITrigger.Binding?, for action: ShortcutAction) {
        midiBindings[action] = binding
        midiTrigger.setBinding(binding, for: action)

        let defaults = UserDefaults.standard
        if let binding {
            defaults.set(Int(binding.status), forKey: action.defaultsKey(Self.midiStatusKey))
            defaults.set(Int(binding.data1), forKey: action.defaultsKey(Self.midiData1Key))
        } else {
            defaults.removeObject(forKey: action.defaultsKey(Self.midiStatusKey))
            defaults.removeObject(forKey: action.defaultsKey(Self.midiData1Key))
        }
    }

    // MARK: - Key names

    private static let functionKeys: [UInt16: String] = [
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7",
        100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12", 105: "F13",
        107: "F14", 113: "F15", 106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20",
    ]

    private static let namedKeys: [UInt16: String] = [
        49: "Space", 36: "Return", 48: "Tab", 51: "Delete", 53: "Esc",
        123: "←", 124: "→", 125: "↓", 126: "↑",
    ]
}
