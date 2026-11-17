import ServiceManagement
import SwiftUI

/// The "Start at Login" registration for this app.
@MainActor
final class LoginItem: ObservableObject {
    @Published private(set) var isEnabled = SMAppService.mainApp.status == .enabled
    @Published private(set) var error: String?

    func refresh() {
        isEnabled = SMAppService.mainApp.status == .enabled
    }

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        refresh()
    }
}

struct SettingsView: View {
    @ObservedObject var host: InstrumentHost
    @ObservedObject var midi: MIDIInput
    @ObservedObject var shortcuts: ToggleShortcuts

    @ObservedObject var login: LoginItem
    @AppStorage(PanelPosition.defaultsKey) private var panelPosition = PanelPosition.topRight

    @AppStorage("settingsTab") private var selectedTab = "general"

    private static let bufferSizes = [64, 128, 256, 512, 1024]

    var body: some View {
        // Fixed-size tabs. Each tab scrolls on its own, so a long MIDI list cannot grow the window.
        // A plain segmented control is used because TabView's bezel gets clipped by the window edges.
        VStack(spacing: 0) {
            Picker("", selection: $selectedTab) {
                Text("General").tag("general")
                Text("Audio").tag("audio")
                Text("MIDI").tag("midi")
                Text("Shortcuts").tag("shortcuts")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .padding(.top, 12)

            switch selectedTab {
            case "audio": audioTab
            case "midi": midiTab
            case "shortcuts": shortcutsTab
            default: generalTab
            }
        }
        // The login item can also be changed in System Settings, so re-read it when shown.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            login.refresh()
        }
        .frame(width: 480, height: 380, alignment: .top)
    }

    private var generalTab: some View {
        Form {
            Section {
                Toggle("Start at Login", isOn: Binding(
                    get: { login.isEnabled },
                    set: { login.setEnabled($0) }
                ))
                if let error = login.error {
                    Text(error).foregroundStyle(.red)
                }
            }

            Section("Window") {
                // The panel observes this setting and moves right away.
                Picker("Location", selection: $panelPosition) {
                    ForEach(PanelPosition.allCases) { position in
                        Label(position.title, systemImage: position.symbolName).tag(position)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var shortcutsTab: some View {
        Form {
            shortcutSection("Show / Hide Plugin", for: .panel)
            shortcutSection("Mute / Unmute", for: .mute)
        }
        .formStyle(.grouped)
    }

    private func shortcutSection(_ title: String, for action: ShortcutAction) -> some View {
        Section(title) {
            LabeledContent("Hotkey") {
                HStack {
                    Text(shortcuts.hotKeys[action]?.display ?? "None").foregroundStyle(.secondary)
                    Button(shortcuts.recordingHotKey == action ? "Press keys..." : "Record") {
                        shortcuts.toggleHotKeyRecording(for: action)
                    }
                    if shortcuts.hotKeys[action] != nil {
                        Button("Clear") { shortcuts.clearHotKey(for: action) }
                    }
                }
            }
            if let error = shortcuts.hotKeyErrors[action] {
                Text(error).foregroundStyle(.red)
            }

            LabeledContent("MIDI command") {
                HStack {
                    Text(shortcuts.midiDescription(for: action) ?? "None").foregroundStyle(.secondary)
                    Button(shortcuts.learningMIDI == action ? "Waiting for MIDI..." : "Learn") {
                        shortcuts.toggleMIDILearn(for: action)
                    }
                    if shortcuts.midiBindings[action] != nil {
                        Button("Clear") { shortcuts.clearMIDI(for: action) }
                    }
                }
            }
        }
    }

    private var audioTab: some View {
        Form {
            Section {
                Picker("Output", selection: Binding(
                    get: { host.outputDeviceUID },
                    set: { host.setOutputDevice(uid: $0) }
                )) {
                    Text("System Default").tag("")
                    ForEach(host.outputDevices) { device in
                        Text(device.name).tag(device.uid)
                    }
                }

                // Only devices with more than one stereo pair have something to choose.
                if host.outputChannelCount > 2 {
                    Picker("Output channels", selection: Binding(
                        get: { host.outputPair },
                        set: { host.setOutputPair($0) }
                    )) {
                        ForEach(0..<(host.outputChannelCount / 2), id: \.self) { pair in
                            Text("\(pair * 2 + 1)-\(pair * 2 + 2)").tag(pair)
                        }
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

                if let error = host.errorMessage {
                    Text(error).foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var midiTab: some View {
        Form {
            Section("Inputs") {
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
    }
}
