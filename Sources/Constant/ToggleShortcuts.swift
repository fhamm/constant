import AppKit
import Carbon.HIToolbox

/// Watches incoming MIDI for the message bound to "show/hide plugin". Runs on the CoreMIDI thread.
final class MIDITrigger: @unchecked Sendable {
    struct Binding: Equatable, Sendable {
        let status: UInt8  // message kind + channel
        let data1: UInt8   // note, controller or program number
    }

    private let lock = NSLock()
    private var binding: Binding?
    private var learning = false
    private var onTrigger: (@Sendable () -> Void)?
    private var onLearned: (@Sendable (Binding) -> Void)?

    func setCallbacks(
        onTrigger: @escaping @Sendable () -> Void,
        onLearned: @escaping @Sendable (Binding) -> Void
    ) {
        lock.lock()
        self.onTrigger = onTrigger
        self.onLearned = onLearned
        lock.unlock()
    }

    func setBinding(_ newBinding: Binding?) {
        lock.lock()
        binding = newBinding
        lock.unlock()
    }

    func setLearning(_ value: Bool) {
        lock.lock()
        learning = value
        lock.unlock()
    }

    /// Returns true when the message belongs to the trigger and must not reach the instrument.
    func handle(status: UInt8, data1: UInt8, data2: UInt8) -> Bool {
        let kind = status & 0xF0
        // A press: note on, controller above zero, or program change.
        let isPress = (kind == 0x90 && data2 > 0) || (kind == 0xB0 && data2 > 0) || kind == 0xC0

        lock.lock()
        defer { lock.unlock() }

        if learning {
            guard isPress else { return false }
            let learned = Binding(status: status, data1: data1)
            binding = learned
            learning = false
            onLearned?(learned)
            return true
        }

        guard let binding, data1 == binding.data1 else { return false }
        // Also swallow the note off that follows a bound note on.
        let isNoteOff = binding.status & 0xF0 == 0x90 && status == binding.status - 0x10
        guard status == binding.status || isNoteOff else { return false }

        if isPress { onTrigger?() }
        return true
    }
}

struct HotKey: Equatable {
    let keyCode: UInt32
    let modifiers: UInt32  // Carbon modifier mask
    let display: String
}

/// Global hotkey and MIDI command that show or hide the plugin panel.
@MainActor
final class ToggleShortcuts: ObservableObject {
    @Published private(set) var hotKey: HotKey?
    @Published private(set) var hotKeyError: String?
    @Published private(set) var isRecordingHotKey = false
    @Published private(set) var midiBinding: MIDITrigger.Binding?
    @Published private(set) var isLearningMIDI = false

    nonisolated let midiTrigger = MIDITrigger()

    /// Called on the main thread when either shortcut fires.
    var onToggle: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var keyMonitor: Any?

    private static let keyCodeKey = "hotKeyCode"
    private static let modifiersKey = "hotKeyModifiers"
    private static let displayKey = "hotKeyDisplay"
    private static let midiStatusKey = "midiTriggerStatus"
    private static let midiData1Key = "midiTriggerData1"

    init() {
        let defaults = UserDefaults.standard
        if let display = defaults.string(forKey: Self.displayKey) {
            hotKey = HotKey(
                keyCode: UInt32(defaults.integer(forKey: Self.keyCodeKey)),
                modifiers: UInt32(defaults.integer(forKey: Self.modifiersKey)),
                display: display)
        }
        if defaults.object(forKey: Self.midiStatusKey) != nil {
            midiBinding = MIDITrigger.Binding(
                status: UInt8(truncatingIfNeeded: defaults.integer(forKey: Self.midiStatusKey)),
                data1: UInt8(truncatingIfNeeded: defaults.integer(forKey: Self.midiData1Key)))
        }

        midiTrigger.setBinding(midiBinding)
        midiTrigger.setCallbacks(
            onTrigger: { [weak self] in
                DispatchQueue.main.async { self?.onToggle?() }
            },
            onLearned: { [weak self] binding in
                DispatchQueue.main.async { self?.midiLearned(binding) }
            })

        installHotKeyHandler()
        registerHotKey()
    }

    /// Stops any hotkey recording or MIDI learn in progress.
    func cancelCapture() {
        if isRecordingHotKey {
            stopKeyMonitor()
            isRecordingHotKey = false
            registerHotKey()
        }
        if isLearningMIDI {
            isLearningMIDI = false
            midiTrigger.setLearning(false)
        }
    }

    // MARK: - Hotkey

    func toggleHotKeyRecording() {
        if isRecordingHotKey {
            cancelCapture()
            return
        }
        cancelCapture()
        unregisterHotKey()  // so pressing the current shortcut records it instead of firing
        hotKeyError = nil
        isRecordingHotKey = true

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

    func clearHotKey() {
        cancelCapture()
        setHotKey(nil)
    }

    private func record(keyCode: UInt16, flags: NSEvent.ModifierFlags, characters: String?) {
        guard isRecordingHotKey else { return }
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
        isRecordingHotKey = false
        setHotKey(HotKey(keyCode: UInt32(keyCode), modifiers: carbon, display: display))
    }

    private func setHotKey(_ newHotKey: HotKey?) {
        unregisterHotKey()
        hotKey = newHotKey
        hotKeyError = nil

        let defaults = UserDefaults.standard
        if let newHotKey {
            defaults.set(Int(newHotKey.keyCode), forKey: Self.keyCodeKey)
            defaults.set(Int(newHotKey.modifiers), forKey: Self.modifiersKey)
            defaults.set(newHotKey.display, forKey: Self.displayKey)
        } else {
            defaults.removeObject(forKey: Self.keyCodeKey)
            defaults.removeObject(forKey: Self.modifiersKey)
            defaults.removeObject(forKey: Self.displayKey)
        }
        registerHotKey()
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
            { _, _, userData in
                guard let userData else { return noErr }
                let shortcuts = Unmanaged<ToggleShortcuts>.fromOpaque(userData).takeUnretainedValue()
                DispatchQueue.main.async { shortcuts.onToggle?() }
                return noErr
            },
            1, &spec, Unmanaged.passUnretained(self).toOpaque(), nil)
    }

    private func registerHotKey() {
        guard let hotKey, hotKeyRef == nil else { return }
        let id = EventHotKeyID(signature: OSType(0x434E_5354), id: 1)  // 'CNST'
        let status = RegisterEventHotKey(
            hotKey.keyCode, hotKey.modifiers, id, GetApplicationEventTarget(), 0, &hotKeyRef)
        if status != noErr {
            hotKeyRef = nil
            hotKeyError = "This shortcut is already used by another app."
        }
    }

    private func unregisterHotKey() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
    }

    // MARK: - MIDI

    var midiDescription: String? {
        guard let binding = midiBinding else { return nil }
        let channel = Int(binding.status & 0x0F) + 1
        switch binding.status & 0xF0 {
        case 0x90: return "Note \(binding.data1), channel \(channel)"
        case 0xB0: return "CC \(binding.data1), channel \(channel)"
        default: return "Program \(binding.data1), channel \(channel)"
        }
    }

    func toggleMIDILearn() {
        if isLearningMIDI {
            cancelCapture()
            return
        }
        cancelCapture()
        isLearningMIDI = true
        midiTrigger.setLearning(true)
    }

    func clearMIDI() {
        cancelCapture()
        setMIDIBinding(nil)
    }

    private func midiLearned(_ binding: MIDITrigger.Binding) {
        isLearningMIDI = false
        setMIDIBinding(binding)
    }

    private func setMIDIBinding(_ binding: MIDITrigger.Binding?) {
        midiBinding = binding
        midiTrigger.setBinding(binding)

        let defaults = UserDefaults.standard
        if let binding {
            defaults.set(Int(binding.status), forKey: Self.midiStatusKey)
            defaults.set(Int(binding.data1), forKey: Self.midiData1Key)
        } else {
            defaults.removeObject(forKey: Self.midiStatusKey)
            defaults.removeObject(forKey: Self.midiData1Key)
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
