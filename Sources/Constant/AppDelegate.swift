import AppKit

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    private let host: InstrumentHost
    private let midi: MIDIInput
    private let shortcuts: ToggleShortcuts
    private var statusItem: StatusItemController?

    override init() {
        host = InstrumentHost()
        shortcuts = ToggleShortcuts()
        midi = MIDIInput(sink: host.midiSink, trigger: shortcuts.midiTrigger)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = StatusItemController(host: host, midi: midi, shortcuts: shortcuts)
        midi.start()

        host.restoreSession()
    }

    func applicationWillTerminate(_ notification: Notification) {
        host.persist()
    }
}
