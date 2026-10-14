import AppKit
import SwiftUI

/// The app's colors, sizes and the few custom-drawn pieces, taken from the
/// app icon: indigo, lavender and the red of its dot. Everything else is
/// standard macOS; views take their values from here instead of spelling
/// out a color or a radius themselves.
enum Brand {
    // MARK: - Colors

    /// The icon's own colors.
    enum Palette {
        static let indigo = Color(hex: 0x4B3FD1)
        static let indigoDark = Color(hex: 0x2A2392)
        static let indigoDeepest = Color(hex: 0x150F4F)
        static let lavender = Color(hex: 0xE4E0FF)
        static let lavenderDeep = Color(hex: 0xC9C4FF)
        static let recordBright = Color(hex: 0xFF3B4E)
        static let recordDeep = Color(hex: 0xD3112B)
    }

    /// The tint of the standard controls, and the asset catalog's
    /// `AccentColor`: #4B3FD1 in light mode, a lightened #8F87FF in dark mode.
    /// macOS writes picker values and button titles in the tint, so it has to
    /// work as text: 5.6:1 or more on the light backgrounds, 4.7:1 on the
    /// dark grouped background and 5.6:1 on the dark window.
    static let accent = Color(light: 0x4B3FD1, dark: 0x8F87FF)

    /// Shapes of our own that carry white text (the selected sidebar row):
    /// the dark mode tint is too light for that (3:1), these give 7.2:1 and 6.1:1.
    static let fill = Color(light: 0x4B3FD1, dark: 0x574BDB)

    /// Our own indigo marks on the window background: icons, the status
    /// dot, frames, the timeline. Lavender in dark mode, as in the icon
    /// (#C9C4FF on the dark backgrounds is 8.5:1 or more).
    static let accentText = Color(light: 0x4B3FD1, dark: 0xC9C4FF)

    /// The quieter partner of `accentText`, for the second of two series.
    static let accentSecondary = Color(light: 0x8E86E8, dark: 0x8F88E6)

    /// The primary button, top to bottom. White on both ends is above 6:1.
    static let primaryGradient = LinearGradient(
        colors: [Color(hex: 0x574BDB), Color(hex: 0x4135C2)], startPoint: .top, endPoint: .bottom
    )

    /// A running recording, top to bottom. The icon's brightest red (#FF3B4E)
    /// is too light under white text (3.5:1), so the fill starts a step
    /// darker (4.7:1) and ends on the icon's deep red (5.4:1).
    static let recordingGradient = LinearGradient(
        colors: [Color(hex: 0xE0203A), Palette.recordDeep], startPoint: .top, endPoint: .bottom
    )

    /// The dot itself, as in the icon. Only ever means "recording".
    static let recordDot = Palette.recordBright

    /// Hairlines around cards and neutral buttons.
    static let hairline = Color(nsColor: .separatorColor)

    // MARK: - Sizes

    /// Everything sits on an 8 pt grid; 4 is the half step inside a text block.
    enum Space {
        static let half: CGFloat = 4
        static let one: CGFloat = 8
        static let two: CGFloat = 16
        static let three: CGFloat = 24
    }

    enum Radius {
        static let card: CGFloat = 12
        /// Buttons, thumbnails, the timeline.
        static let control: CGFloat = 8
        /// Sidebar rows.
        static let row: CGFloat = 6
    }

    static let dotSize: CGFloat = 8

    // MARK: - What a status dot says

    /// A dot never stands alone: the text next to it says the same thing.
    enum Status {
        case capturing, recording, idle, problem

        var color: Color {
            switch self {
            case .capturing: return Brand.accentText
            case .recording: return Brand.recordDot
            case .idle: return Color.secondary
            case .problem: return Color.orange
            }
        }

        /// The same colors for the menu bar menu, which takes images.
        var menuImage: NSImage {
            let color: NSColor
            switch self {
            case .capturing: color = NSColor(name: nil) { $0.isDark ? NSColor(hex: 0xC9C4FF) : NSColor(hex: 0x4B3FD1) }
            case .recording: color = NSColor(hex: 0xFF3B4E)
            case .idle: color = .secondaryLabelColor
            case .problem: color = .systemOrange
            }
            let image = NSImage(size: NSSize(width: 10, height: 10), flipped: false) { rect in
                color.setFill()
                NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
                return true
            }
            image.isTemplate = false
            return image
        }
    }
}

// MARK: - Buttons

/// The filled, indigo button: "Save Last N Seconds", and the one action a
/// sheet or panel is there for. `isCompact` sizes it like a standard button.
struct PrimaryButtonStyle: ButtonStyle {
    var isCompact = false

    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.vertical, isCompact ? Brand.Space.half : Brand.Space.one)
            .padding(.horizontal, isCompact ? Brand.Space.one + Brand.Space.half : Brand.Space.two)
            .background(Brand.primaryGradient, in: RoundedRectangle(cornerRadius: Brand.Radius.control, style: .continuous))
            .overlay(Color.black.opacity(configuration.isPressed ? 0.18 : 0).clipShape(RoundedRectangle(cornerRadius: Brand.Radius.control, style: .continuous)))
            .opacity(isEnabled ? 1 : 0.5)
            .contentShape(Rectangle())
    }
}

/// "Start Recording": neutral until a recording runs, then red.
struct RecordingButtonStyle: ButtonStyle {
    let isRecording: Bool

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: Brand.Radius.control, style: .continuous)
        configuration.label
            .font(.body.weight(isRecording ? .semibold : .regular))
            .foregroundStyle(isRecording ? Color.white : Color.primary)
            .padding(.vertical, Brand.Space.one)
            .padding(.horizontal, Brand.Space.two)
            .background {
                if isRecording {
                    shape.fill(Brand.recordingGradient)
                } else {
                    shape.fill(Color(nsColor: .controlColor))
                    shape.strokeBorder(Brand.hairline)
                }
            }
            .overlay(Color.black.opacity(configuration.isPressed ? 0.15 : 0).clipShape(shape))
            .contentShape(Rectangle())
    }
}

/// The icon's red dot. While `isLive` its glow breathes, unless the user
/// asked for reduced motion; then it just glows.
struct RecordDot: View {
    var size: CGFloat = Brand.dotSize
    var isLive = true
    /// On the red button a red dot would vanish; there it is drawn white.
    var onRed = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isBright = false

    var body: some View {
        Circle()
            .fill(onRed ? Color.white : Brand.recordDot)
            .frame(width: size, height: size)
            .shadow(color: (onRed ? Color.white : Brand.recordDot).opacity(isLive ? (isBright ? 0.9 : 0.45) : 0), radius: isBright ? size * 0.7 : size * 0.3)
            .onAppear {
                guard isLive, !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 1).repeatForever(autoreverses: true)) { isBright = true }
            }
    }
}

// MARK: - The icon's glyph

/// The app icon's mark, an arrow circling back around a dot, drawn in
/// faded brand colors for empty states.
struct BrandGlyph: View {
    var size: CGFloat = 96

    var body: some View {
        Canvas { context, canvas in
            let center = CGPoint(x: canvas.width / 2, y: canvas.height / 2)
            let radius = canvas.width * 0.34
            let width = canvas.width * 0.105
            // From about one o'clock the long way round to about four o'clock.
            let start = Angle.degrees(-62), end = Angle.degrees(28)
            var ring = Path()
            ring.addArc(center: center, radius: radius, startAngle: start, endAngle: end, clockwise: true)
            context.stroke(ring, with: .color(Brand.accentText.opacity(0.4)), style: StrokeStyle(lineWidth: width, lineCap: .round))

            // The arrowhead continues the way the ring was travelling.
            let tip = CGPoint(x: center.x + radius * cos(end.radians), y: center.y + radius * sin(end.radians))
            let along = CGVector(dx: sin(end.radians), dy: -cos(end.radians))
            let across = CGVector(dx: cos(end.radians), dy: sin(end.radians))
            var head = Path()
            head.move(to: CGPoint(x: tip.x + along.dx * width * 1.5, y: tip.y + along.dy * width * 1.5))
            head.addLine(to: CGPoint(x: tip.x + across.dx * width * 1.25 - along.dx * width * 0.2, y: tip.y + across.dy * width * 1.25 - along.dy * width * 0.2))
            head.addLine(to: CGPoint(x: tip.x - across.dx * width * 1.25 - along.dx * width * 0.2, y: tip.y - across.dy * width * 1.25 - along.dy * width * 0.2))
            head.closeSubpath()
            context.fill(head, with: .color(Brand.accentText.opacity(0.4)))

            let dot = canvas.width * 0.15
            context.fill(
                Path(ellipseIn: CGRect(x: center.x - dot, y: center.y - dot, width: dot * 2, height: dot * 2)),
                with: .color(Brand.recordDot.opacity(0.55))
            )
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Glyph, title and a short explanation, for a list with nothing in it.
struct EmptyStateView: View {
    let title: LocalizedStringKey
    let message: LocalizedStringKey

    var body: some View {
        VStack(spacing: Brand.Space.one) {
            BrandGlyph()
                .padding(.bottom, Brand.Space.one)
            Text(title)
                .font(.title3.weight(.semibold))
            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .padding(Brand.Space.three)
    }
}

// MARK: - Helpers

extension Color {
    init(hex: UInt32) {
        self.init(nsColor: NSColor(hex: hex))
    }

    /// One color per appearance, resolved by AppKit when it is drawn.
    init(light: UInt32, dark: UInt32) {
        self.init(nsColor: NSColor(name: nil) { $0.isDark ? NSColor(hex: dark) : NSColor(hex: light) })
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: 1
        )
    }
}

private extension NSAppearance {
    var isDark: Bool { bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
}
