import AppKit
import ServiceManagement
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
    private let shortcuts: ToggleShortcuts
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let panel: PluginPanelController
    private let menu = NSMenu()
    private var settingsWindow: NSWindow?
    private let positionMenu = NSMenu()
    private lazy var loginItem = makeItem("Start at Login", #selector(toggleStartAtLogin))

    init(host: InstrumentHost, midi: MIDIInput, shortcuts: ToggleShortcuts) {
        self.host = host
        self.midi = midi
        self.shortcuts = shortcuts
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

        menu.addItem(loginItem)
        menu.addItem(.separator())

        let positionItem = NSMenuItem(title: "Location", action: nil, keyEquivalent: "")
        for position in PanelPosition.allCases {
            let item = makeItem(position.title, #selector(selectPosition(_:)))
            item.representedObject = position.rawValue
            item.image = NSImage(systemSymbolName: position.symbolName, accessibilityDescription: nil)
            // macOS 27 hides menu item images unless the item asks for them.
            if #available(macOS 27.0, *) { item.preferredImageVisibility = .visible }
            positionMenu.addItem(item)
        }
        positionItem.submenu = positionMenu
        menu.addItem(positionItem)
        menu.addItem(.separator())
        menu.addItem(makeItem("Settings", #selector(openSettings), key: ","))
        menu.addItem(makeItem("About", #selector(openAbout)))
        menu.addItem(.separator())
        menu.addItem(makeItem("Quit", #selector(quit), key: "q"))

        panel.onOpenSettings = { [weak self] in self?.openSettings() }
        shortcuts.onToggle = { [weak self] in
            guard let self, let button = self.statusItem.button else { return }
            self.panel.toggle(relativeTo: button)
        }
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
            loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
            let currentPosition = PanelPosition.current.rawValue
            for item in positionMenu.items {
                item.state = item.representedObject as? String == currentPosition ? .on : .off
            }
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
            let controller = NSHostingController(rootView: SettingsView(host: host, midi: midi, shortcuts: shortcuts))
            // Let the window grow and shrink with the MIDI input list.
            controller.sizingOptions = [.preferredContentSize]
            let window = SettingsWindow(contentViewController: controller)
            window.title = "Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window

            // Do not leave a hotkey recording or MIDI learn running after the window closes.
            NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: window, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.shortcuts.cancelCapture() }
            }
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

    @objc private func selectPosition(_ sender: NSMenuItem) {
        // The panel observes this setting and moves right away.
        UserDefaults.standard.set(sender.representedObject as? String, forKey: PanelPosition.defaultsKey)
    }

    @objc private func toggleStartAtLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "Could not change Start at Login"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
