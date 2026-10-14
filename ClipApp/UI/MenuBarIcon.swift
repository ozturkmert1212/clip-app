import AppKit

/// The menu bar icon in its three states. It never shows anything but the
/// icon: no text, no counter.
struct MenuBarIcon {
    static let shared = MenuBarIcon(template: NSImage(named: "MenuBarIcon") ?? NSImage())

    static let size = NSSize(width: 18, height: 18)
    /// Where the dot sits in the artwork, in points from the bottom left.
    private static let dotCenter = CGPoint(x: 9, y: 9)
    private static let dotRadius: CGFloat = 2.5
    /// Slightly more than the dot, less than the gap to the arrowhead.
    private static let dotClearance: CGFloat = 2.75
    /// The app icon's dot (#FF3B4E).
    private static let recordColor = NSColor(srgbRed: 1, green: 0x3B / 255.0, blue: 0x4E / 255.0, alpha: 1)

    /// Capturing: the artwork as a template, which the menu bar colors itself.
    let normal: NSImage
    /// Capture is off, failing or not permitted: the same at half strength.
    let dimmed: NSImage
    /// A recording is running: ring and arrow in the menu bar's own text
    /// color, the dot in red. Drawn on demand, so it follows the appearance
    /// it is drawn in and is sharp at every scale.
    let recording: NSImage

    init(template: NSImage) {
        let artwork = template.copy() as? NSImage ?? template
        artwork.size = Self.size
        artwork.isTemplate = true
        normal = artwork

        // Still a template: the menu bar tints it, at half the opacity.
        dimmed = NSImage(size: Self.size, flipped: false) { rect in
            artwork.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 0.5)
            return true
        }
        dimmed.isTemplate = true

        recording = NSImage(size: Self.size, flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            let dot = CGRect(
                x: Self.dotCenter.x - Self.dotRadius, y: Self.dotCenter.y - Self.dotRadius,
                width: Self.dotRadius * 2, height: Self.dotRadius * 2
            )
            // Ring and arrow: the artwork without its dot, in the text color of
            // whatever this is drawn on (dark on a light menu bar, light on a dark one).
            context.saveGState()
            context.beginTransparencyLayer(auxiliaryInfo: nil)
            artwork.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
            context.setBlendMode(.clear)
            context.fillEllipse(in: dot.insetBy(dx: Self.dotRadius - Self.dotClearance, dy: Self.dotRadius - Self.dotClearance))
            context.setBlendMode(.sourceIn)
            context.setFillColor(NSColor.labelColor.cgColor)
            context.fill(rect)
            context.endTransparencyLayer()
            context.restoreGState()

            context.setFillColor(Self.recordColor.cgColor)
            context.fillEllipse(in: dot)
            return true
        }
        recording.isTemplate = false
    }
}
