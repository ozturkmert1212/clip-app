import AppKit
import SwiftUI

/// Brief on-screen confirmation in a corner of the screen. Exists because macOS
/// hides notification banners while the screen is being captured, which for
/// this app is always.
@MainActor
final class HUD {
    enum Kind {
        case success, failure
    }

    /// Games keep minimaps and menus in the corners, so the user picks one.
    /// Top right is also where notification banners appear.
    enum Corner: String, CaseIterable, Identifiable {
        case topLeft, topRight, bottomLeft, bottomRight

        var id: String { rawValue }

        var title: String {
            switch self {
            case .topLeft: return AppLanguage.string("Top left")
            case .topRight: return AppLanguage.string("Top right")
            case .bottomLeft: return AppLanguage.string("Bottom left")
            case .bottomRight: return AppLanguage.string("Bottom right")
            }
        }

        fileprivate var isLeft: Bool { self == .topLeft || self == .bottomLeft }
        fileprivate var isTop: Bool { self == .topLeft || self == .topRight }
    }

    private static let visibleSeconds: TimeInterval = 2.5
    private static let margin: CGFloat = 16

    private let panel: NSPanel
    private let hosting = NSHostingView(rootView: HUDView(kind: .success, title: "", detail: nil))
    private var hideTask: Task<Void, Never>?

    /// For `CaptureManager.excludedWindowIDs`. Valid from `init` on because the
    /// panel is not deferred.
    var windowID: CGWindowID { CGWindowID(panel.windowNumber) }

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        // Above full screen games, and on whichever Space is showing.
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        // Belt and braces: capture also excludes the panel by window ID, which
        // is the part to rely on with ScreenCaptureKit.
        panel.sharingType = .none
        panel.contentView = hosting
    }

    func show(_ kind: Kind, title: String, detail: String? = nil, in corner: Corner) {
        hideTask?.cancel()
        hosting.rootView = HUDView(kind: kind, title: title, detail: detail)
        let size = hosting.fittingSize
        // `main` is the screen with keyboard focus, i.e. where the game is.
        let screen = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? .zero
        panel.setFrame(
            NSRect(
                x: corner.isLeft ? screen.minX + Self.margin : screen.maxX - size.width - Self.margin,
                y: corner.isTop ? screen.maxY - size.height - Self.margin : screen.minY + Self.margin,
                width: size.width,
                height: size.height
            ),
            display: true
        )
        panel.alphaValue = 1
        panel.orderFrontRegardless()

        hideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.visibleSeconds * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            await NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                self.panel.animator().alphaValue = 0
            }
            // A newer message may have taken over during the fade.
            guard !Task.isCancelled else { return }
            self.panel.orderOut(nil)
        }
    }
}

private struct HUDView: View {
    let kind: HUD.Kind
    let title: String
    let detail: String?

    var body: some View {
        HStack(spacing: Brand.Space.one) {
            Image(systemName: kind == .success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.title2)
                .foregroundStyle(kind == .success ? Brand.success : Color.yellow)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.white)
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.75))
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
            }
        }
        .padding(.horizontal, Brand.Space.two)
        .padding(.vertical, Brand.Space.one)
        .frame(maxWidth: 340, alignment: .leading)
        .fixedSize()
        .background(Color.black.opacity(0.8), in: RoundedRectangle(cornerRadius: Brand.Radius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Brand.Radius.card, style: .continuous)
                .strokeBorder(Color.white.opacity(0.15), lineWidth: 1)
        )
    }
}
