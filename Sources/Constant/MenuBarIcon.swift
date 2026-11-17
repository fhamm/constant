import AppKit

/// Menu bar icons: the keyboard symbol plus a variation for each state.
enum MenuBarIcon {
    enum State {
        case playing
        case loading
        case noInstrument
        case muted
    }

    static func image(for state: State) -> NSImage? {
        guard let base = NSImage(systemSymbolName: "pianokeys", accessibilityDescription: nil) else {
            return nil
        }
        let size = base.size
        let image = NSImage(size: size, flipped: false) { rect in
            switch state {
            case .playing:
                base.draw(in: rect)

            case .loading:
                // Faded keyboard while a plugin loads.
                base.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 0.35)

            case .muted:
                // Angled line over the keyboard, like speaker.slash: top left to bottom right,
                // with a gap cut around it so it reads against the keys.
                base.draw(in: rect)
                let slash = NSBezierPath()
                slash.move(to: NSPoint(x: rect.minX + 1, y: rect.maxY - 0.5))
                slash.line(to: NSPoint(x: rect.maxX - 1, y: rect.minY + 0.5))
                slash.lineCapStyle = .round
                cutOut { slash.lineWidth = 4; slash.stroke() }
                slash.lineWidth = 1.5
                slash.stroke()

            case .noInstrument:
                // Small x badge in the bottom right corner.
                base.draw(in: rect)
                let radius = rect.height * 0.3
                let center = NSPoint(x: rect.maxX - radius, y: rect.minY + radius)
                let badge = NSBezierPath(ovalIn: NSRect(
                    x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
                cutOut { badge.fill() }

                let arm = radius * 0.45
                let cross = NSBezierPath()
                cross.move(to: NSPoint(x: center.x - arm, y: center.y - arm))
                cross.line(to: NSPoint(x: center.x + arm, y: center.y + arm))
                cross.move(to: NSPoint(x: center.x - arm, y: center.y + arm))
                cross.line(to: NSPoint(x: center.x + arm, y: center.y - arm))
                cross.lineWidth = 1.5
                cross.lineCapStyle = .round
                cross.stroke()
            }
            return true
        }
        // Template, so the menu bar tints it for light and dark mode.
        image.isTemplate = true
        image.accessibilityDescription = "Constant"
        return image
    }

    /// Runs the drawing as an eraser, clearing whatever it covers.
    private static func cutOut(_ draw: () -> Void) {
        guard let context = NSGraphicsContext.current else { return }
        context.saveGraphicsState()
        context.compositingOperation = .destinationOut
        draw()
        context.restoreGraphicsState()
    }
}
