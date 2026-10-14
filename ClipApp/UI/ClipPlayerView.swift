import AVKit
import SwiftUI

@MainActor
final class ClipPlayerModel: ObservableObject {
    enum Outcome {
        case saved(String)
        case failed(String)
    }

    enum AudioLayout {
        case loading
        /// No audio, or nothing known about it.
        case none
        /// One track, or tracks whose roles are unknown: nothing to adjust.
        case single
        /// Game audio and microphone are there as tracks of their own.
        case stems
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
    @Published private(set) var audioLayout = AudioLayout.loading
    /// Linear gains for the preview and for the next save, 1 = as recorded.
    @Published var systemLevel = 1.0 { didSet { applyLevels() } }
    @Published var microphoneLevel = 1.0 { didSet { applyLevels() } }
    @Published var systemMuted = false { didSet { applyLevels() } }
    @Published var microphoneMuted = false { didSet { applyLevels() } }
    /// Peaks of each source over the clip, 0...1.
    @Published private(set) var waveforms: [ClipInfo.AudioRole: [Float]] = [:]
    /// 0...1 while a trimmed clip is being written, `nil` otherwise.
    @Published private(set) var exportProgress: Double?
    @Published private(set) var outcome: Outcome?

    private var timeObserver: Any?
    private var stopsAtTrimEnd = false
    private var exportTask: Task<Void, Never>?
    private let onTrimmed: () -> Void
    /// The levels the file's mixed track was made with.
    private var savedEdit = ClipTrimmer.AudioEdit()
    /// The preview's own copies of the two source tracks.
    private var previewTracks: [AVCompositionTrack] = []

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
            let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
            guard let time = try? await asset.load(.duration), time.isNumeric else { return }
            duration = time.seconds
            trimEnd = time.seconds
            await loadAudio(asset, duration: time)
        }
    }

    /// In a clip with separate source tracks the file's own mix is replaced,
    /// for the preview, by the two sources played together at the chosen
    /// levels; they are marked disabled in the file, so the player would
    /// otherwise never touch them.
    private func loadAudio(_ asset: AVURLAsset, duration: CMTime) async {
        let tracks = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
        let info = await ClipInfo.read(from: asset)
        guard let roles = info?.audio, roles.count == tracks.count,
              let system = roles.firstIndex(of: .system), let microphone = roles.firstIndex(of: .microphone),
              let video = try? await asset.loadTracks(withMediaType: .video).first else {
            audioLayout = tracks.isEmpty ? .none : .single
            return
        }
        let composition = AVMutableComposition()
        let whole = CMTimeRange(start: .zero, duration: duration)
        do {
            let picture = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
            try picture?.insertTimeRange(whole, of: video, at: .zero)
            picture?.preferredTransform = (try? await video.load(.preferredTransform)) ?? .identity
            previewTracks = try [tracks[system], tracks[microphone]].compactMap { track in
                let copy = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
                try copy?.insertTimeRange(whole, of: track, at: .zero)
                return copy
            }
        } catch {
            audioLayout = .single
            return
        }
        guard previewTracks.count == 2 else {
            audioLayout = .single
            return
        }
        if let levels = info?.levels {
            savedEdit.system = levels[ClipInfo.AudioRole.system.rawValue] ?? 1
            savedEdit.microphone = levels[ClipInfo.AudioRole.microphone.rawValue] ?? 1
        }
        // A level of zero comes back as muted, with the slider left at 100 %.
        systemMuted = savedEdit.system == 0
        systemLevel = savedEdit.system == 0 ? 1 : savedEdit.system
        microphoneMuted = savedEdit.microphone == 0
        microphoneLevel = savedEdit.microphone == 0 ? 1 : savedEdit.microphone

        let wasPlaying = player.rate != 0
        let position = player.currentTime()
        player.replaceCurrentItem(with: AVPlayerItem(asset: composition))
        audioLayout = .stems
        applyLevels()
        await player.seek(to: position, toleranceBefore: .zero, toleranceAfter: .zero)
        if wasPlaying { player.play() }

        for (role, track) in [(ClipInfo.AudioRole.system, tracks[system]), (.microphone, tracks[microphone])] {
            waveforms[role] = await Task.detached(priority: .utility) {
                await Self.peaks(of: track, in: asset, duration: duration)
            }.value
        }
    }

    private var audioEdit: ClipTrimmer.AudioEdit {
        ClipTrimmer.AudioEdit(
            system: systemMuted ? 0 : systemLevel,
            microphone: microphoneMuted ? 0 : microphoneLevel
        )
    }

    /// The levels differ from the ones the file was saved with.
    var isAudioChanged: Bool { audioLayout == .stems && audioEdit != savedEdit }

    var canSave: Bool { isTrimmed || isAudioChanged }

    private func applyLevels() {
        guard previewTracks.count == 2 else { return }
        let edit = audioEdit
        let mix = AVMutableAudioMix()
        mix.inputParameters = zip(previewTracks, [edit.system, edit.microphone]).map { track, level in
            let parameters = AVMutableAudioMixInputParameters(track: track)
            parameters.setVolume(Float(level), at: .zero)
            return parameters
        }
        player.currentItem?.audioMix = mix
    }

    /// The loudest sample in each of `count` equal slices of the track.
    nonisolated private static func peaks(of track: AVAssetTrack, in asset: AVAsset, duration: CMTime, count: Int = 400) async -> [Float] {
        guard let description = try? await track.load(.formatDescriptions).first?.audioStreamBasicDescription,
              let reader = try? AVAssetReader(asset: asset) else { return [] }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return [] }
        reader.add(output)
        guard reader.startReading() else { return [] }

        let channels = max(1, Int(description.mChannelsPerFrame))
        let total = max(1, Int(duration.seconds * description.mSampleRate))
        var peaks = [Float](repeating: 0, count: count)
        var frame = 0
        while let buffer = output.copyNextSampleBuffer() {
            var pointer: UnsafeMutablePointer<CChar>?
            var length = 0
            guard let block = buffer.dataBuffer,
                  CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer) == noErr,
                  let pointer else { continue }
            let frames = length / (2 * channels)
            pointer.withMemoryRebound(to: Int16.self, capacity: frames * channels) { samples in
                for i in 0..<frames {
                    let slot = min(count - 1, (frame + i) * count / total)
                    for channel in 0..<channels {
                        let value = Float(abs(Int32(samples[i * channels + channel]))) / 32768
                        if value > peaks[slot] { peaks[slot] = value }
                    }
                }
            }
            frame += frames
        }
        return peaks
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
        guard exportTask == nil, canSave else { return }
        let range = CMTimeRange(
            start: CMTime(seconds: trimStart, preferredTimescale: 600),
            end: CMTime(seconds: trimEnd, preferredTimescale: 600)
        )
        let mode: ClipTrimmer.Mode = precise ? .reencode : .passthrough
        // Unchanged levels leave the file's own mix as it is.
        let audio = isAudioChanged ? audioEdit : nil
        let isFullLength = !isTrimmed
        outcome = nil
        exportProgress = 0
        exportTask = Task {
            do {
                let saved = try await ClipTrimmer.trim(url, range: range, mode: mode, audio: audio, isFullLength: isFullLength) {
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

    /// The controls to the left of the timeline and the waveforms.
    private static let leading: CGFloat = 290

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 0) {
                Label("Trim", systemImage: "scissors")
                    .frame(width: Self.leading, alignment: .leading)
                TrimTimeline(
                    duration: model.duration,
                    current: model.currentTime,
                    start: model.trimStart,
                    end: model.trimEnd,
                    onStart: model.setTrimStart,
                    onEnd: model.setTrimEnd,
                    onSeek: model.seek
                )
            }
            switch model.audioLayout {
            case .stems:
                AudioRow(
                    title: "Game audio", systemImage: "gamecontroller",
                    level: $model.systemLevel, isMuted: $model.systemMuted,
                    peaks: model.waveforms[.system] ?? []
                )
                AudioRow(
                    title: "Microphone", systemImage: "mic",
                    level: $model.microphoneLevel, isMuted: $model.microphoneMuted,
                    peaks: model.waveforms[.microphone] ?? []
                )
            case .single:
                Text("Audio was saved as a single track, so game audio and microphone can't be adjusted separately.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .loading, .none:
                EmptyView()
            }
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
                    Button("Save Edited Clip", action: model.saveTrimmed)
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.canSave)
                }
            }
            .disabled(model.duration == 0)

            switch model.outcome {
            case .saved(let name):
                Label("Saved as \(name)", systemImage: "checkmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.green)
            case .failed(let message):
                Label("Couldn't save the edited clip: \(message)", systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            case nil:
                EmptyView()
            }
        }
        .padding(12)
    }

    /// One audio source: mute, level and its waveform under the timeline.
    private struct AudioRow: View {
        let title: LocalizedStringKey
        let systemImage: String
        @Binding var level: Double
        @Binding var isMuted: Bool
        let peaks: [Float]

        var body: some View {
            HStack(spacing: 0) {
                HStack(spacing: 6) {
                    Label(title, systemImage: systemImage)
                        .lineLimit(1)
                        .frame(width: 104, alignment: .leading)
                    Button {
                        isMuted.toggle()
                    } label: {
                        Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            .frame(width: 18)
                    }
                    .buttonStyle(.borderless)
                    .help(isMuted ? "Unmute" : "Mute")
                    Slider(value: $level, in: 0...1.5, step: 0.05)
                        .disabled(isMuted)
                    Text(verbatim: "\(Int((level * 100).rounded()))%")
                        .font(.caption)
                        .monospacedDigit()
                        .frame(width: 36, alignment: .trailing)
                }
                .padding(.trailing, 10)
                .frame(width: TrimPanel.leading, alignment: .leading)
                Waveform(peaks: peaks, gain: isMuted ? 0 : level)
                    // Lines up with the timeline's bar, which is inset by its handles.
                    .padding(.horizontal, TrimTimeline.handleWidth)
                    .frame(height: 26)
            }
        }
    }

    private struct Waveform: View {
        let peaks: [Float]
        let gain: Double

        var body: some View {
            Canvas { context, size in
                // Drawn relative to the track's own loudest point, which sits at
                // two thirds of the height so that 150 % still fits.
                guard let loudest = peaks.max(), loudest > 0 else { return }
                let scale = CGFloat(gain) / 1.5 / CGFloat(loudest)
                let step = size.width / CGFloat(peaks.count)
                var path = Path()
                for (index, peak) in peaks.enumerated() {
                    let height = max(1, min(1, CGFloat(peak) * scale) * size.height)
                    path.addRect(CGRect(
                        x: CGFloat(index) * step, y: (size.height - height) / 2,
                        width: max(1, step - 0.5), height: height
                    ))
                }
                context.fill(path, with: .color(.accentColor.opacity(gain == 0 ? 0.3 : 0.8)))
            }
            .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
        }
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

    static let handleWidth: CGFloat = 12
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
