import AVKit
import SwiftUI

@MainActor
final class ClipPlayerModel: ObservableObject {
    enum Outcome {
        case saved(String)
        case failed(String)
    }

    /// The shortest selection the handles allow.
    static let minimumLength: TimeInterval = 0.5

    let url: URL
    let player: AVPlayer

    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var trimStart: TimeInterval = 0
    @Published private(set) var trimEnd: TimeInterval = 0
    @Published var precise = false
    /// 0...1 while a trimmed clip is being written, `nil` otherwise.
    @Published private(set) var exportProgress: Double?
    @Published private(set) var outcome: Outcome?

    private var timeObserver: Any?
    private var stopsAtTrimEnd = false
    private var exportTask: Task<Void, Never>?
    private let onTrimmed: () -> Void

    /// `onTrimmed` is called after a trimmed clip was written.
    init(url: URL, onTrimmed: @escaping () -> Void) {
        self.url = url
        self.onTrimmed = onTrimmed
        player = AVPlayer(url: url)
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 30),
            queue: .main
        ) { [weak self] time in
            let seconds = time.seconds
            Task { @MainActor in self?.tick(seconds) }
        }
        Task {
            guard let time = try? await AVURLAsset(url: url).load(.duration), time.isNumeric else { return }
            duration = time.seconds
            trimEnd = time.seconds
        }
    }

    deinit {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
    }

    var isTrimmed: Bool { duration > 0 && (trimStart > 0.01 || trimEnd < duration - 0.01) }

    func setTrimStart(_ time: TimeInterval) {
        trimStart = min(max(0, time), trimEnd - Self.minimumLength)
        preview(trimStart)
    }

    func setTrimEnd(_ time: TimeInterval) {
        trimEnd = max(min(duration, time), trimStart + Self.minimumLength)
        preview(trimEnd)
    }

    func seek(to time: TimeInterval) {
        stopsAtTrimEnd = false
        show(min(max(0, time), duration))
    }

    func playSelection() {
        show(trimStart)
        stopsAtTrimEnd = true
        player.play()
    }

    func saveTrimmed() {
        guard exportTask == nil, isTrimmed else { return }
        let range = CMTimeRange(
            start: CMTime(seconds: trimStart, preferredTimescale: 600),
            end: CMTime(seconds: trimEnd, preferredTimescale: 600)
        )
        let mode: ClipTrimmer.Mode = precise ? .reencode : .passthrough
        outcome = nil
        exportProgress = 0
        exportTask = Task {
            do {
                let saved = try await ClipTrimmer.trim(url, range: range, mode: mode) {
                    self.exportProgress = $0
                }
                outcome = .saved(saved.lastPathComponent)
                onTrimmed()
            } catch is CancellationError {
                outcome = nil
            } catch {
                outcome = .failed(error.localizedDescription)
            }
            exportProgress = nil
            exportTask = nil
        }
    }

    func cancelExport() {
        exportTask?.cancel()
    }

    /// Dragging a handle shows the frame it is on.
    private func preview(_ time: TimeInterval) {
        player.pause()
        stopsAtTrimEnd = false
        show(time)
    }

    private func show(_ time: TimeInterval) {
        currentTime = time
        player.seek(to: CMTime(seconds: time, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func tick(_ time: TimeInterval) {
        guard time.isFinite else { return }
        // While paused the position is whatever was last asked for.
        guard player.rate != 0 else { return }
        currentTime = time
        if stopsAtTrimEnd, time >= trimEnd {
            stopsAtTrimEnd = false
            player.pause()
        }
    }
}

struct ClipPlayerView: View {
    let clip: ClipItem
    let onClose: () -> Void

    @StateObject private var model: ClipPlayerModel

    init(clip: ClipItem, onTrimmed: @escaping () -> Void, onClose: @escaping () -> Void) {
        self.clip = clip
        self.onClose = onClose
        // An autoclosure: the model is only built for the first of the view's values.
        _model = StateObject(wrappedValue: ClipPlayerModel(url: clip.url, onTrimmed: onTrimmed))
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
            Divider()
            TrimPanel(model: model)
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

private struct TrimPanel: View {
    @ObservedObject var model: ClipPlayerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TrimTimeline(
                duration: model.duration,
                current: model.currentTime,
                start: model.trimStart,
                end: model.trimEnd,
                onStart: model.setTrimStart,
                onEnd: model.setTrimEnd,
                onSeek: model.seek
            )
            HStack(spacing: 16) {
                Text("Start \(ClipFormat.duration(model.trimStart, tenths: true))")
                Text("End \(ClipFormat.duration(model.trimEnd, tenths: true))")
                Text("Length \(ClipFormat.duration(model.trimEnd - model.trimStart, tenths: true))")
                Spacer()
                Button("Play Selection", action: model.playSelection)
            }
            .font(.callout)
            .monospacedDigit()

            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Toggle("Precise (re-encode)", isOn: $model.precise)
                    Text(model.precise
                         ? "Re-encodes the video at the source's bitrate so the file holds exactly the selected range. Slower, with a slight loss in quality."
                         : "Copies the video as it is: instant and lossless. Because a cut can only start on a keyframe (every 2 s), the file keeps up to 2 s of hidden footage before the start; most players skip it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if let progress = model.exportProgress {
                    ProgressView(value: progress)
                        .frame(width: 120)
                    Button("Cancel", action: model.cancelExport)
                } else {
                    Button("Save Trimmed Clip", action: model.saveTrimmed)
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.isTrimmed)
                }
            }
            .disabled(model.duration == 0)

            switch model.outcome {
            case .saved(let name):
                Label("Saved as \(name)", systemImage: "checkmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.green)
            case .failed(let message):
                Label("Couldn't save the trimmed clip: \(message)", systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            case nil:
                EmptyView()
            }
        }
        .padding(12)
    }
}

/// A bar for the whole clip with a handle at each end of the selection and a
/// line at the playback position. Clicking or dragging the bar seeks.
private struct TrimTimeline: View {
    let duration: TimeInterval
    let current: TimeInterval
    let start: TimeInterval
    let end: TimeInterval
    let onStart: (TimeInterval) -> Void
    let onEnd: (TimeInterval) -> Void
    let onSeek: (TimeInterval) -> Void

    private static let handleWidth: CGFloat = 12
    private static let space = "timeline"

    var body: some View {
        GeometryReader { geometry in
            // The handles sit outside the selection, so the bar is inset by one on each side.
            let usable = max(1, geometry.size.width - Self.handleWidth * 2)
            let position = { (time: TimeInterval) -> CGFloat in
                Self.handleWidth + usable * CGFloat(duration > 0 ? time / duration : 0)
            }
            let time = { (x: CGFloat) -> TimeInterval in
                duration * Double(min(max(0, (x - Self.handleWidth) / usable), 1))
            }

            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.secondary.opacity(0.25))
                    .contentShape(Rectangle())
                    .gesture(drag { onSeek(time($0)) })
                Rectangle()
                    .fill(Color.accentColor.opacity(0.35))
                    .frame(width: max(0, position(end) - position(start)))
                    .offset(x: position(start))
                    .allowsHitTesting(false)
                handle
                    .offset(x: position(start) - Self.handleWidth)
                    .gesture(drag { onStart(time($0)) })
                handle
                    .offset(x: position(end))
                    .gesture(drag { onEnd(time($0)) })
                Rectangle()
                    .fill(Color.primary)
                    .frame(width: 2)
                    .offset(x: position(min(max(0, current), duration)) - 1)
                    .allowsHitTesting(false)
            }
            .coordinateSpace(name: Self.space)
        }
        .frame(height: 34)
    }

    private var handle: some View {
        RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(Color.accentColor)
            .frame(width: Self.handleWidth)
            .overlay {
                Capsule()
                    .fill(Color.white.opacity(0.9))
                    .frame(width: 2, height: 14)
            }
            .contentShape(Rectangle())
    }

    private func drag(_ action: @escaping (CGFloat) -> Void) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space))
            .onChanged { action($0.location.x) }
    }
}
