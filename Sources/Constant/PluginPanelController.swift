import AppKit
import SwiftUI

/// Borderless panel that can still take keyboard focus (plugin search fields, text entry).
final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Shows the hosted instrument's editor in a panel placed at the chosen screen location.
@MainActor
final class PluginPanelController {
    private let host: InstrumentHost
    private let panel: KeyPanel
    private weak var anchor: NSView?
    private var pluginViewController: NSViewController?
    private var frameObserver: NSObjectProtocol?
    private var reloadToken = 0

    init(host: InstrumentHost) {
        self.host = host
        panel = KeyPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 140),
            styleMask: [.borderless], backing: .buffered, defer: true)
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.hasShadow = true
        panel.backgroundColor = .windowBackgroundColor
        panel.collectionBehavior = [.moveToActiveSpace]
        reload()

        // Move the panel right away when the position setting changes.
        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reposition() }
        }
    }

    // MARK: - Visibility

    func toggle(relativeTo view: NSView) {
        anchor = view
        if panel.isVisible {
            hide()
        } else {
            show()
        }
    }

    private func show() {
        reposition()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    private func hide() {
        panel.orderOut(nil)
        host.persist()
    }

    // MARK: - Content

    /// Rebuilds the panel content for the host's current state.
    func reload() {
        reloadToken += 1
        let token = reloadToken
        clearPluginView()

        if host.isLoading {
            showMessage("Loading \(host.current?.name ?? "plugin")...")
        } else if !host.isReady {
            showMessage(host.errorMessage
                ?? "No instrument selected.\nRight click the menu bar icon to choose one.")
        } else {
            host.requestViewController { [weak self] viewController in
                guard let self, token == self.reloadToken else { return }
                if let viewController {
                    self.install(viewController)
                } else {
                    self.showMessage("This plugin has no interface.")
                }
            }
        }
    }

    private func clearPluginView() {
        if let frameObserver { NotificationCenter.default.removeObserver(frameObserver) }
        frameObserver = nil
        pluginViewController?.view.removeFromSuperview()
        pluginViewController = nil
    }

    private func showMessage(_ message: String) {
        let view = NSHostingView(rootView: MessageView(message: message))
        let size = view.fittingSize
        view.frame = NSRect(origin: .zero, size: size)
        panel.contentView = view
        panel.setContentSize(size)
        reposition()
    }

    private func install(_ viewController: NSViewController) {
        let view = viewController.view
        var size = view.frame.size
        if size.width < 1 || size.height < 1 { size = viewController.preferredContentSize }
        let hasOwnSize = size.width >= 1 && size.height >= 1
        if !hasOwnSize { size = NSSize(width: 640, height: 420) }

        let container = NSView(frame: NSRect(origin: .zero, size: size))
        view.frame = container.bounds
        if !hasOwnSize { view.autoresizingMask = [.width, .height] }
        container.addSubview(view)

        pluginViewController = viewController
        panel.contentView = container
        panel.setContentSize(size)
        reposition()

        // Follow the plugin when it resizes itself (zoom, expanded views).
        view.postsFrameChangedNotifications = true
        frameObserver = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification, object: view, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.pluginViewResized() }
        }
    }

    private func pluginViewResized() {
        guard let view = pluginViewController?.view, let content = panel.contentView else { return }
        let size = view.frame.size
        guard size.width >= 1, size.height >= 1, size != content.frame.size else { return }
        panel.setContentSize(size)
        view.setFrameOrigin(.zero)
        reposition()
    }

    // MARK: - Placement

    private func reposition() {
        guard let itemWindow = anchor?.window else { return }
        let size = panel.frame.size
        let margin: CGFloat = 8

        // Positions are relative to the screen whose menu bar icon was clicked.
        guard let visible = (itemWindow.screen ?? NSScreen.main)?.visibleFrame else { return }
        let left = visible.minX + margin
        let right = visible.maxX - size.width - margin
        let top = visible.maxY - size.height - margin
        let bottom = visible.minY + margin

        let origin: NSPoint
        switch PanelPosition.current {
        case .center:
            origin = NSPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2)
        case .topLeft: origin = NSPoint(x: left, y: top)
        case .topRight: origin = NSPoint(x: right, y: top)
        case .bottomLeft: origin = NSPoint(x: left, y: bottom)
        case .bottomRight: origin = NSPoint(x: right, y: bottom)
        }
        guard origin != panel.frame.origin else { return }
        panel.setFrameOrigin(origin)
    }
}

/// Where the plugin panel appears on screen.
enum PanelPosition: String, CaseIterable, Identifiable {
    case topRight, topLeft, center, bottomLeft, bottomRight

    static let defaultsKey = "panelPosition"

    static var current: PanelPosition {
        UserDefaults.standard.string(forKey: defaultsKey).flatMap(PanelPosition.init) ?? .topRight
    }

    var id: String { rawValue }

    /// SF Symbol shown next to the position in Settings.
    var symbolName: String {
        switch self {
        case .center: return "rectangle.center.inset.filled"
        case .topLeft: return "rectangle.inset.topleft.filled"
        case .topRight: return "rectangle.inset.topright.filled"
        case .bottomLeft: return "rectangle.inset.bottomleft.filled"
        case .bottomRight: return "rectangle.inset.bottomright.filled"
        }
    }

    var title: String {
        switch self {
        case .center: return "Center"
        case .topLeft: return "Top Left"
        case .topRight: return "Top Right"
        case .bottomLeft: return "Bottom Left"
        case .bottomRight: return "Bottom Right"
        }
    }
}

private struct MessageView: View {
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "pianokeys")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text(message)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(24)
        .frame(width: 320)
    }
}
