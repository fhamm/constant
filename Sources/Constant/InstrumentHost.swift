import AVFoundation
@preconcurrency import AudioToolbox
import CoreAudioKit

struct InstrumentInfo: Identifiable, Hashable {
    let id: String
    let name: String
    let manufacturer: String
    let description: AudioComponentDescription

    init(_ component: AVAudioUnitComponent) {
        let d = component.audioComponentDescription
        id = "\(d.componentType)-\(d.componentSubType)-\(d.componentManufacturer)"
        name = component.name
        manufacturer = component.manufacturerName
        description = d
    }

    static func == (lhs: InstrumentInfo, rhs: InstrumentInfo) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// Thread-safe hand-off of MIDI bytes from the CoreMIDI thread to the loaded instrument.
final class MIDISink: @unchecked Sendable {
    private let lock = NSLock()
    private var block: AUScheduleMIDIEventBlock?

    func set(_ newBlock: AUScheduleMIDIEventBlock?) {
        lock.lock()
        block = newBlock
        lock.unlock()
    }

    func send(_ bytes: UnsafePointer<UInt8>, count: Int) {
        lock.lock()
        let current = block
        lock.unlock()
        current?(AUEventSampleTimeImmediate, 0, count, bytes)
    }
}

/// Hosts exactly one virtual instrument: the audio engine, the Audio Unit and its saved state.
@MainActor
final class InstrumentHost: ObservableObject {
    @Published private(set) var instruments: [InstrumentInfo] = []
    @Published private(set) var current: InstrumentInfo?
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var outputDevices: [AudioDevice] = []
    @Published private(set) var outputDeviceUID: String
    @Published private(set) var bufferSize: Int

    nonisolated let midiSink = MIDISink()

    /// Called whenever the instrument or its loading state changes.
    var onInstrumentChanged: (() -> Void)?

    var isReady: Bool { unit != nil }

    private let engine = AVAudioEngine()
    private var unit: AVAudioUnit?
    private var loadToken = 0
    private var overrodeDevice = false

    private static let deviceKey = "outputDeviceUID"
    private static let bufferKey = "bufferSize"

    private static let sessionURL: URL = {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Constant", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("session.plist")
    }()

    init() {
        outputDeviceUID = UserDefaults.standard.string(forKey: Self.deviceKey) ?? ""
        bufferSize = UserDefaults.standard.integer(forKey: Self.bufferKey)

        NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.startEngine() }
        }
    }

    // MARK: - Discovery

    func refreshInstruments() {
        let any = AudioComponentDescription(
            componentType: kAudioUnitType_MusicDevice,
            componentSubType: 0, componentManufacturer: 0,
            componentFlags: 0, componentFlagsMask: 0)
        instruments = AVAudioUnitComponentManager.shared()
            .components(matching: any)
            .map(InstrumentInfo.init)
            .sorted {
                ($0.manufacturer.lowercased(), $0.name.lowercased())
                    < ($1.manufacturer.lowercased(), $1.name.lowercased())
            }
    }

    func refreshOutputDevices() {
        outputDevices = AudioDevices.outputDevices()
    }

    // MARK: - Loading

    func select(id: String) {
        guard id != (current?.id ?? "") else { return }
        select(instruments.first { $0.id == id })
    }

    func select(_ info: InstrumentInfo?, restoring state: [String: Any]? = nil) {
        unload()
        current = info
        errorMessage = nil
        loadToken += 1

        guard let info else {
            isLoading = false
            persist()
            onInstrumentChanged?()
            return
        }

        isLoading = true
        onInstrumentChanged?()

        let token = loadToken
        AVAudioUnit.instantiate(with: info.description, options: []) { [weak self] unit, error in
            DispatchQueue.main.async {
                guard let self, token == self.loadToken else { return }
                self.isLoading = false
                if let unit {
                    if let state { unit.auAudioUnit.fullState = state }
                    self.unit = unit
                    self.engine.attach(unit)
                    self.startEngine()
                    self.persist()
                } else {
                    self.errorMessage = error?.localizedDescription ?? "Could not load \(info.name)."
                }
                self.onInstrumentChanged?()
            }
        }
    }

    private func unload() {
        midiSink.set(nil)
        engine.stop()
        if let unit { engine.detach(unit) }
        unit = nil
    }

    // MARK: - Engine

    private func startEngine() {
        guard let unit else { return }
        midiSink.set(nil)
        engine.stop()
        applyOutputSettings()

        let hardwareRate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        let format = AVAudioFormat(
            standardFormatWithSampleRate: hardwareRate > 0 ? hardwareRate : 44100, channels: 2)
        engine.connect(unit, to: engine.mainMixerNode, format: format)

        do {
            engine.prepare()
            try engine.start()
            midiSink.set(unit.auAudioUnit.scheduleMIDIEventBlock)
            errorMessage = nil
        } catch {
            errorMessage = "Audio engine failed to start: \(error.localizedDescription)"
        }
    }

    private func applyOutputSettings() {
        refreshOutputDevices()

        let wanted: AudioDeviceID?
        if outputDeviceUID.isEmpty {
            // Only force the default device if we previously pointed the engine elsewhere.
            wanted = overrodeDevice ? AudioDevices.defaultOutputDevice() : nil
        } else {
            wanted = outputDevices.first { $0.uid == outputDeviceUID }?.id
        }

        if let wanted, let outputUnit = engine.outputNode.audioUnit {
            var currentID = AudioDeviceID(0)
            var size = UInt32(MemoryLayout<AudioDeviceID>.size)
            AudioUnitGetProperty(
                outputUnit, kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global, 0, &currentID, &size)
            if currentID != wanted {
                var newID = wanted
                AudioUnitSetProperty(
                    outputUnit, kAudioOutputUnitProperty_CurrentDevice,
                    kAudioUnitScope_Global, 0, &newID, size)
                overrodeDevice = true
            }
        }

        if bufferSize > 0, let device = wanted ?? AudioDevices.defaultOutputDevice() {
            AudioDevices.setBufferSize(UInt32(bufferSize), on: device)
        }
    }

    func setOutputDevice(uid: String) {
        guard uid != outputDeviceUID else { return }
        outputDeviceUID = uid
        UserDefaults.standard.set(uid, forKey: Self.deviceKey)
        startEngine()
    }

    func setBufferSize(_ frames: Int) {
        guard frames != bufferSize else { return }
        bufferSize = frames
        UserDefaults.standard.set(frames, forKey: Self.bufferKey)
        startEngine()
    }

    // MARK: - Plugin UI

    func requestViewController(_ completion: @escaping (NSViewController?) -> Void) {
        guard let audioUnit = unit?.auAudioUnit else {
            completion(nil)
            return
        }
        audioUnit.requestViewController { viewController in
            DispatchQueue.main.async {
                if let viewController {
                    completion(viewController)
                } else {
                    // The plugin has no custom editor, fall back to Apple's generic parameter view.
                    let generic = AUGenericViewController()
                    generic.auAudioUnit = audioUnit
                    completion(generic)
                }
            }
        }
    }

    // MARK: - Session

    /// Saves the selected instrument and its full state (patch, settings).
    func persist() {
        var session: [String: Any] = [:]
        if let current {
            // Still loading or failed to load: keep whatever was saved before.
            guard let unit else { return }
            session["instrument"] = current.id
            if let state = unit.auAudioUnit.fullState { session["state"] = state }
        }
        guard let data = try? PropertyListSerialization.data(
            fromPropertyList: session, format: .binary, options: 0) else { return }
        try? data.write(to: Self.sessionURL, options: .atomic)
    }

    func restoreSession() {
        refreshInstruments()
        refreshOutputDevices()

        guard let data = try? Data(contentsOf: Self.sessionURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let session = plist as? [String: Any],
              let id = session["instrument"] as? String,
              let info = instruments.first(where: { $0.id == id })
        else { return }

        select(info, restoring: session["state"] as? [String: Any])
    }
}
