import CoreMIDI
import Foundation

struct MIDISource: Identifiable, Hashable {
    /// CoreMIDI unique ID, stable across reconnects.
    let id: Int32
    let name: String
}

/// Receives MIDI from all sources, or only from the ones the user enabled,
/// and forwards channel messages to the sink as MIDI 1.0 bytes.
@MainActor
final class MIDIInput: ObservableObject {
    @Published private(set) var sources: [MIDISource] = []
    @Published private(set) var listenToAll: Bool
    @Published private(set) var enabledIDs: Set<Int32>

    private let sink: MIDISink
    private let trigger: MIDITrigger
    private var client = MIDIClientRef()
    private var port = MIDIPortRef()
    private var connected: [MIDIEndpointRef] = []

    private static let allKey = "midiListenToAll"
    private static let enabledKey = "midiEnabledInputs"

    init(sink: MIDISink, trigger: MIDITrigger) {
        self.sink = sink
        self.trigger = trigger
        let defaults = UserDefaults.standard
        listenToAll = defaults.object(forKey: Self.allKey) as? Bool ?? true
        let saved = defaults.array(forKey: Self.enabledKey) as? [Int] ?? []
        enabledIDs = Set(saved.map { Int32(truncatingIfNeeded: $0) })
    }

    func start() {
        MIDIClientCreateWithBlock("Constant" as CFString, &client) { [weak self] notification in
            guard notification.pointee.messageID == .msgSetupChanged else { return }
            DispatchQueue.main.async { self?.refresh() }
        }
        let sink = self.sink
        let trigger = self.trigger
        MIDIInputPortCreateWithProtocol(client, "Constant Input" as CFString, ._1_0, &port) { list, _ in
            MIDIInput.forward(list, to: sink, trigger: trigger)
        }
        refresh()
    }

    // MARK: - Configuration

    func setListenToAll(_ value: Bool) {
        listenToAll = value
        UserDefaults.standard.set(value, forKey: Self.allKey)
        refresh()
    }

    func setEnabled(_ enabled: Bool, id: Int32) {
        if enabled { enabledIDs.insert(id) } else { enabledIDs.remove(id) }
        UserDefaults.standard.set(enabledIDs.map { Int($0) }, forKey: Self.enabledKey)
        refresh()
    }

    /// Re-reads the source list and reconnects according to the current selection.
    func refresh() {
        for endpoint in connected { MIDIPortDisconnectSource(port, endpoint) }
        connected = []

        var found: [MIDISource] = []
        for index in 0..<MIDIGetNumberOfSources() {
            let endpoint = MIDIGetSource(index)
            var id: Int32 = 0
            MIDIObjectGetIntegerProperty(endpoint, kMIDIPropertyUniqueID, &id)
            found.append(MIDISource(id: id, name: Self.name(of: endpoint)))

            if listenToAll || enabledIDs.contains(id) {
                MIDIPortConnectSource(port, endpoint, nil)
                connected.append(endpoint)
            }
        }
        sources = found
    }

    private static func name(of endpoint: MIDIEndpointRef) -> String {
        var value: Unmanaged<CFString>?
        MIDIObjectGetStringProperty(endpoint, kMIDIPropertyDisplayName, &value)
        return (value?.takeRetainedValue() as String?) ?? "Unknown input"
    }

    // MARK: - Receiving (CoreMIDI thread)

    nonisolated private static func forward(
        _ list: UnsafePointer<MIDIEventList>, to sink: MIDISink, trigger: MIDITrigger
    ) {
        let wordsOffset = MemoryLayout<MIDIEventPacket>.offset(of: \.words)!

        for packet in list.unsafeSequence() {
            let count = Int(packet.pointee.wordCount)
            let words = UnsafeRawPointer(packet)
                .advanced(by: wordsOffset)
                .assumingMemoryBound(to: UInt32.self)

            var index = 0
            while index < count {
                let word = words[index]
                let type = (word >> 28) & 0xF

                if type == 0x2 {
                    // MIDI 1.0 channel voice message packed in one word.
                    let status = UInt8((word >> 16) & 0xFF)
                    var message = (status, UInt8((word >> 8) & 0x7F), UInt8(word & 0x7F))
                    let kind = status & 0xF0
                    let length = (kind == 0xC0 || kind == 0xD0) ? 2 : 3
                    // The show/hide trigger keeps its own message away from the instrument.
                    if !trigger.handle(status: status, data1: message.1, data2: message.2) {
                        withUnsafeBytes(of: &message) { raw in
                            sink.send(raw.bindMemory(to: UInt8.self).baseAddress!, count: length)
                        }
                    }
                }

                index += wordCount(forType: type)
            }
        }
    }

    /// Size of a Universal MIDI Packet in 32-bit words, by message type.
    nonisolated private static func wordCount(forType type: UInt32) -> Int {
        switch type {
        case 0x0, 0x1, 0x2, 0x6, 0x7: return 1
        case 0x3, 0x4, 0x8, 0x9, 0xA: return 2
        case 0xB, 0xC: return 3
        default: return 4
        }
    }
}
