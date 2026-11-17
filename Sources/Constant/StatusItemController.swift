import AppKit
import SwiftUI

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
    private let pluginMenu = NSMenu()
    private var keyMonitor: Any?
    private let login = LoginItem()
    private lazy var muteItem = makeItem("Mute", #selector(toggleMute), icon: "speaker.slash")

    init(host: InstrumentHost, midi: MIDIInput, shortcuts: ToggleShortcuts) {
        self.host = host
        self.midi = midi
        self.shortcuts = shortcuts
        panel = PluginPanelController(host: host)
        super.init()

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(clicked(_:))
            // React on mouse down, like native menu bar items.
            button.sendAction(on: [.leftMouseDown, .rightMouseDown])
        }

        let pluginItem = NSMenuItem(title: "Instrument", action: nil, keyEquivalent: "")
        pluginItem.submenu = pluginMenu
        setIcon("pianokeys", on: pluginItem)
        menu.addItem(muteItem)
        menu.addItem(.separator())
        menu.addItem(pluginItem)
        menu.addItem(.separator())
        menu.addItem(makeItem("Settings", #selector(openSettings), key: ",", icon: "gearshape"))
        menu.addItem(makeItem("About", #selector(openAbout), icon: "info.circle"))
        menu.addItem(.separator())
        menu.addItem(makeItem("Quit", #selector(quit), key: "q", icon: "power"))

        shortcuts.onTrigger = { [weak self] action in
            guard let self else { return }
            switch action {
            case .panel:
                if let button = self.statusItem.button { self.panel.toggle(relativeTo: button) }
            case .mute:
                self.toggleMute()
            }
        }
        host.onInstrumentChanged = { [weak self] in self?.instrumentChanged() }

        // The app has no main menu, so Cmd+, is handled here for whichever of our windows is
        // focused, including the plugin panel.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard modifiers == .command, event.charactersIgnoringModifiers == "," else { return event }
            let handled = MainActor.assumeIsolated { self?.toggleSettings() ?? false }
            return handled ? nil : event
        }
        instrumentChanged()
    }

    private func makeItem(
        _ title: String, _ action: Selector, key: String = "", icon: String? = nil
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        if let icon { setIcon(icon, on: item) }
        return item
    }

    private func setIcon(_ symbolName: String, on item: NSMenuItem) {
        item.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        // macOS 27 hides menu item images unless the item asks for them.
        if #available(macOS 27.0, *) { item.preferredImageVisibility = .visible }
    }

    private func instrumentChanged() {
        updateIcon()
        panel.reload()
    }

    /// Shows the app's state in the menu bar icon and its tooltip.
    private func updateIcon() {
        let state: MenuBarIcon.State
        if host.isMuted {
            state = .muted
        } else if host.isLoading {
            state = .loading
        } else if !host.isReady {
            state = .noInstrument  // none selected, or it failed to load
        } else {
            state = .playing
        }
        statusItem.button?.image = MenuBarIcon.image(for: state)

        var tip = host.current.map { "Constant - \($0.name)" } ?? "Constant"
        if host.isMuted { tip += " (muted)" }
        statusItem.button?.toolTip = tip
    }

    // MARK: - Actions

    @objc private func clicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        let isRightClick = event?.type == .rightMouseDown
            || event?.modifierFlags.contains(.control) == true

        if isRightClick {
            rebuildPluginMenu()
            muteItem.state = host.isMuted ? .on : .off
            // Attach the menu only for this click so left click keeps its own action.
            statusItem.menu = menu
            sender.performClick(nil)
            statusItem.menu = nil
        } else {
            panel.toggle(relativeTo: sender)
        }
    }

    /// Cmd+, opens Settings, or closes it when it is already focused.
    private func toggleSettings() -> Bool {
        // Let the hotkey recorder capture the keys instead.
        guard !shortcuts.isRecordingHotKey else { return false }
        if let settingsWindow, settingsWindow.isKeyWindow {
            settingsWindow.close()
        } else {
            openSettings()
        }
        return true
    }

    @objc private func openSettings() {
        host.refreshOutputDevices()
        midi.refresh()

        if settingsWindow == nil {
            let controller = NSHostingController(rootView: SettingsView(
                host: host, midi: midi, shortcuts: shortcuts, login: login))
            controller.sizingOptions = [.preferredContentSize]
            let window = NSWindow(contentViewController: controller)
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

    /// Lists installed instruments grouped by manufacturer, with the current one checked.
    private func rebuildPluginMenu() {
        host.refreshInstruments()
        pluginMenu.removeAllItems()
        let currentID = host.current?.id

        let none = makeItem("None", #selector(selectPlugin(_:)))
        none.representedObject = ""
        none.state = currentID == nil ? .on : .off
        pluginMenu.addItem(none)
        pluginMenu.addItem(.separator())

        let groups = Dictionary(grouping: host.instruments, by: \.manufacturer)
        let manufacturers = groups.keys.sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
        for manufacturer in manufacturers {
            let submenu = NSMenu()
            var containsCurrent = false
            for instrument in groups[manufacturer] ?? [] {
                let item = makeItem(instrument.name, #selector(selectPlugin(_:)))
                item.representedObject = instrument.id
                if instrument.id == currentID {
                    item.state = .on
                    containsCurrent = true
                }
                submenu.addItem(item)
            }
            let parent = NSMenuItem(title: manufacturer, action: nil, keyEquivalent: "")
            parent.submenu = submenu
            parent.state = containsCurrent ? .on : .off
            pluginMenu.addItem(parent)
        }
    }

    @objc private func selectPlugin(_ sender: NSMenuItem) {
        host.select(id: sender.representedObject as? String ?? "")
    }

    @objc private func toggleMute() {
        host.setMuted(!host.isMuted)
        updateIcon()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
