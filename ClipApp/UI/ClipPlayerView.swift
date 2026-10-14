import AVKit
import SwiftUI

@MainActor
final class ClipPlayerModel: ObservableObject {
    let url: URL
    let player: AVPlayer

    init(url: URL) {
        self.url = url
        player = AVPlayer(url: url)
    }
}

struct ClipPlayerView: View {
    let clip: ClipItem
    let onClose: () -> Void

    @StateObject private var model: ClipPlayerModel

    init(clip: ClipItem, onClose: @escaping () -> Void) {
        self.clip = clip
        self.onClose = onClose
        _model = StateObject(wrappedValue: ClipPlayerModel(url: clip.url))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button(action: onClose) {
                    Label("Clips", systemImage: "chevron.left")
                }
                Text(verbatim: clip.name)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
            }
            .padding(10)
            Divider()
            PlayerSurface(player: model.player)
        }
        .onAppear { model.player.play() }
        .onDisappear { model.player.pause() }
        // Closing the window only hides it, so the view never disappears.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { notification in
            if (notification.object as? NSWindow)?.frameAutosaveName == WindowManager.mainFrameName {
                model.player.pause()
            }
        }
    }
}

private struct PlayerSurface: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.videoGravity = .resizeAspect
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
}
