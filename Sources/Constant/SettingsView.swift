import SwiftUI

struct SettingsView: View {
    @ObservedObject var host: InstrumentHost
    @ObservedObject var midi: MIDIInput
    @ObservedObject var shortcuts: ToggleShortcuts

    private static let bufferSizes = [64, 128, 256, 512, 1024]

    var body: some View {
        Form {
            Section("Instrument") {
                Picker("Plugin", selection: Binding(
                    get: { host.current?.id ?? "" },
                    set: { host.select(id: $0) }
                )) {
                    Text("None").tag("")
                    ForEach(host.instruments) { instrument in
                        Text("\(instrument.manufacturer) - \(instrument.name)").tag(instrument.id)
                    }
                }

                if host.isLoading {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Loading...").foregroundStyle(.secondary)
                    }
                }
                if let error = host.errorMessage {
                    Text(error).foregroundStyle(.red)
                }
            }

            Section("Show / Hide Plugin") {
                LabeledContent("Hotkey") {
                    HStack {
                        Text(shortcuts.hotKey?.display ?? "None").foregroundStyle(.secondary)
                        Button(shortcuts.isRecordingHotKey ? "Press keys..." : "Record") {
                            shortcuts.toggleHotKeyRecording()
                        }
                        if shortcuts.hotKey != nil {
                            Button("Clear") { shortcuts.clearHotKey() }
                        }
                    }
                }
                if let error = shortcuts.hotKeyError {
                    Text(error).foregroundStyle(.red)
                }

                LabeledContent("MIDI command") {
                    HStack {
                        Text(shortcuts.midiDescription ?? "None").foregroundStyle(.secondary)
                        Button(shortcuts.isLearningMIDI ? "Waiting for MIDI..." : "Learn") {
                            shortcuts.toggleMIDILearn()
                        }
                        if shortcuts.midiBinding != nil {
                            Button("Clear") { shortcuts.clearMIDI() }
                        }
                    }
                }
            }

            Section("Audio") {
                Picker("Output", selection: Binding(
                    get: { host.outputDeviceUID },
                    set: { host.setOutputDevice(uid: $0) }
                )) {
                    Text("System Default").tag("")
                    ForEach(host.outputDevices) { device in
                        Text(device.name).tag(device.uid)
                    }
                }

                Picker("Buffer size", selection: Binding(
                    get: { host.bufferSize },
                    set: { host.setBufferSize($0) }
                )) {
                    Text("Device Default").tag(0)
                    ForEach(Self.bufferSizes, id: \.self) { size in
                        Text("\(size) samples").tag(size)
                    }
                }
            }

            Section("MIDI Inputs") {
                Toggle("All inputs", isOn: Binding(
                    get: { midi.listenToAll },
                    set: { midi.setListenToAll($0) }
                ))

                if midi.sources.isEmpty {
                    Text("No MIDI inputs connected.").foregroundStyle(.secondary)
                }
                ForEach(midi.sources) { source in
                    Toggle(source.name, isOn: Binding(
                        get: { midi.listenToAll || midi.enabledIDs.contains(source.id) },
                        set: { midi.setEnabled($0, id: source.id) }
                    ))
                    .disabled(midi.listenToAll)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }
}
