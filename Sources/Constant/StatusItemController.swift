import AppKit
import SwiftUI

/// Settings window that closes on Cmd+, (the app has no main menu to handle shortcuts).
final class SettingsWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers == .command, event.charactersIgnoringModifiers == "," {
            close()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// Menu bar icon: left click toggles the plugin panel, right click opens the context menu.
@MainActor
final class StatusItemController: NSObject {
    private let host: InstrumentHost
    private let midi: MIDIInput
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let panel: PluginPanelController
    private let menu = NSMenu()
    private var settingsWindow: NSWindow?

    init(host: InstrumentHost, midi: MIDIInput) {
        self.host = host
        self.midi = midi
        panel = PluginPanelController(host: host)
        super.init()

        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "pianokeys", accessibilityDescription: "Constant")
            image?.isTemplate = true
            button.image = image
            button.target = self
            button.action = #selector(clicked(_:))
            // React on mouse down, like native menu bar items.
            button.sendAction(on: [.leftMouseDown, .rightMouseDown])
        }

        menu.addItem(makeItem("Settings", #selector(openSettings), key: ","))
        menu.addItem(makeItem("About", #selector(openAbout)))
        menu.addItem(.separator())
        menu.addItem(makeItem("Quit", #selector(quit), key: "q"))

        panel.onOpenSettings = { [weak self] in self?.openSettings() }
        host.onInstrumentChanged = { [weak self] in self?.instrumentChanged() }
        instrumentChanged()
    }

    private func makeItem(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    private func instrumentChanged() {
        statusItem.button?.toolTip = host.current.map { "Constant - \($0.name)" } ?? "Constant"
        panel.reload()
    }

    // MARK: - Actions

    @objc private func clicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        let isRightClick = event?.type == .rightMouseDown
            || event?.modifierFlags.contains(.control) == true

        if isRightClick {
            // Attach the menu only for this click so left click keeps its own action.
            statusItem.menu = menu
            sender.performClick(nil)
            statusItem.menu = nil
        } else {
            panel.toggle(relativeTo: sender)
        }
    }

    @objc private func openSettings() {
        host.refreshInstruments()
        host.refreshOutputDevices()
        midi.refresh()

        if settingsWindow == nil {
            let controller = NSHostingController(rootView: SettingsView(host: host, midi: midi))
            // Let the window grow and shrink with the MIDI input list.
            controller.sizingOptions = [.preferredContentSize]
            let window = SettingsWindow(contentViewController: controller)
            window.title = "Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func openAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Constant",
            .credits: NSAttributedString(
                string: "A menu bar host for Audio Unit instruments.",
                attributes: [
                    .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                    .foregroundColor: NSColor.secondaryLabelColor,
                ]),
        ])
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
