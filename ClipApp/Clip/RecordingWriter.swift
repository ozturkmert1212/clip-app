import AVFoundation
import CoreMedia

/// Writes a recording straight to disk while it runs: the encoder's samples
/// as they are, audio as AAC in the same layout as a clip (see `ClipWriter`).
/// The file is written in movie fragments, so a recording that is cut off by
/// a crash or a kill stays playable up to the last fragment.
///
/// Samples arrive from the capture threads; everything is done on one queue.
final class RecordingWriter: @unchecked Sendable {
    enum RecordingError: LocalizedError {
        case noFrames
        case formatChanged
        case overloaded
        case writerFailed(Error?)

        var errorDescription: String? {
            switch self {
            case .noFrames: return AppLanguage.string("Nothing was captured during the recording")
            case .formatChanged: return AppLanguage.string("The capture size changed, so the recording was ended")
            case .overloaded: return AppLanguage.string("The disk couldn't keep up with the recording")
            case .writerFailed(let error): return error?.localizedDescription ?? AppLanguage.string("Couldn't write the recording")
            }
        }
    }

    struct Outcome {
        /// The finished file; `nil` when nothing usable was written.
        let url: URL?
        /// Why the recording ended early or failed, if it did.
        let error: RecordingError?
    }

    private static let fragmentInterval = CMTime(seconds: 5, preferredTimescale: 600)

    let url: URL
    private let queue = DispatchQueue(label: "com.mertozturk.ClipApp.recording", qos: .userInitiated)
    private let writer: AVAssetWriter
    private let videoFormat: CMFormatDescription
    private let video: Feed
    private var groups: [AudioGroup] = []
    private var feeds: [Feed] = []
    private var startTime: CMTime?
    /// The newest frame waits here until the next one arrives; the last one
    /// of the recording is stretched to its end before it is written.
    private var heldVideo: CMSampleBuffer?
    private var failure: RecordingError?
    private let onFailure: (RecordingError) -> Void

    /// `videoFormat` and `audioFormats` are what the pipeline currently puts
    /// out. With two audio sources of the same format the first audio track
    /// is their mix and, with `keepStems`, each follows as a disabled track.
    /// `onFailure` is called once, on the writer's queue, when the recording
    /// cannot go on; `finish` still has to be called.
    init(
        url: URL,
        videoFormat: CMFormatDescription,
        audioFormats: [(track: AudioTrack, format: CMAudioFormatDescription)],
        keepStems: Bool,
        info: ClipInfo,
        onFailure: @escaping (RecordingError) -> Void
    ) throws {
        self.url = url
        self.videoFormat = videoFormat
        self.onFailure = onFailure
        do {
            writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        } catch {
            throw RecordingError.writerFailed(error)
        }
        writer.movieFragmentInterval = Self.fragmentInterval

        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: videoFormat)
        videoInput.expectsMediaDataInRealTime = true
        guard writer.canAdd(videoInput) else { throw RecordingError.writerFailed(nil) }
        writer.add(videoInput)
        video = Feed(videoInput)
        feeds = [video]

        var roles: [ClipInfo.AudioRole] = []
        func feed(_ role: ClipInfo.AudioRole, _ format: CMAudioFormatDescription, enabled: Bool) -> Feed? {
            guard let description = format.audioStreamBasicDescription else { return nil }
            var settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: description.mSampleRate,
                AVNumberOfChannelsKey: Int(description.mChannelsPerFrame),
            ]
            if description.mSampleRate >= 44_100 {
                settings[AVEncoderBitRateKey] = 96_000 * Int(description.mChannelsPerFrame)
            }
            guard writer.canApply(outputSettings: settings, forMediaType: .audio) else { return nil }
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings, sourceFormatHint: format)
            input.expectsMediaDataInRealTime = true
            input.marksOutputTrackAsEnabled = enabled
            guard writer.canAdd(input) else { return nil }
            writer.add(input)
            roles.append(role)
            let feed = Feed(input)
            feeds.append(feed)
            return feed
        }
        func role(_ track: AudioTrack) -> ClipInfo.AudioRole { track == .system ? .system : .microphone }

        if audioFormats.count > 1,
           audioFormats.dropFirst().allSatisfy({ CMFormatDescriptionEqual($0.format, otherFormatDescription: audioFormats[0].format) }) {
            let format = audioFormats[0].format
            if let mix = feed(.mix, format, enabled: true) {
                let lanes = audioFormats.map {
                    AudioGroup.Lane(track: $0.track, stem: keepStems ? feed(role($0.track), format, enabled: false) : nil)
                }
                groups = [AudioGroup(format: format, lanes: lanes, mix: mix)]
            }
        } else {
            // One source, or sources that cannot be added up: an ordinary track each.
            groups = audioFormats.compactMap { source in
                guard let stem = feed(role(source.track), source.format, enabled: true) else { return nil }
                return AudioGroup(format: source.format, lanes: [AudioGroup.Lane(track: source.track, stem: stem)], mix: nil)
            }
        }

        var info = info
        info.audio = roles
        writer.metadata = info.metadataItems
        guard writer.startWriting() else { throw RecordingError.writerFailed(writer.error) }
    }

    func appendVideo(_ sample: CMSampleBuffer) {
        queue.async { [self] in
            guard failure == nil else { return }
            let sameFormat = sample.formatDescription.map { CMFormatDescriptionEqual($0, otherFormatDescription: videoFormat) } ?? false
            if startTime == nil {
                // Nothing is decodable before the first keyframe.
                guard RingBuffer.isKeyframe(sample) else { return }
                guard sameFormat else { return fail(.formatChanged) }
                startTime = sample.presentationTimeStamp
                writer.startSession(atSourceTime: sample.presentationTimeStamp)
            } else if !sameFormat {
                // One track cannot switch parameter sets.
                return fail(.formatChanged)
            }
            if let held = heldVideo { push(held, to: video) }
            heldVideo = sample
        }
    }

    func appendAudio(_ sample: CMSampleBuffer, from track: AudioTrack) {
        queue.async { [self] in
            guard failure == nil, let startTime else { return }
            for group in groups {
                group.append(sample, from: track, start: startTime)
                for (buffer, feed) in group.flush(start: startTime, final: false) { push(buffer, to: feed) }
            }
        }
    }

    /// Ends the recording at `end` (host clock) and closes the file.
    func finish(at end: CMTime) async -> Outcome {
        await withCheckedContinuation { (continuation: CheckedContinuation<Outcome, Never>) in
            queue.async { [self] in
                guard let startTime, writer.status == .writing else {
                    let error = failure ?? (writer.status == .failed ? .writerFailed(writer.error) : .noFrames)
                    writer.cancelWriting()
                    try? FileManager.default.removeItem(at: url)
                    continuation.resume(returning: Outcome(url: nil, error: error))
                    return
                }
                var end = end
                if let held = heldVideo {
                    end = max(end, held.presentationTimeStamp + CMTime(value: 1, timescale: 600))
                    push(Self.retimed(held, duration: end - held.presentationTimeStamp), to: video)
                    heldVideo = nil
                }
                for group in groups {
                    group.pad(to: end, start: startTime)
                    for (buffer, feed) in group.flush(start: startTime, final: true) { push(buffer, to: feed) }
                }
                // Whatever the inputs had no room for a moment ago still goes in.
                for _ in 0..<400 where feeds.contains(where: { !$0.backlog.isEmpty }) {
                    usleep(5_000)
                    feeds.forEach { _ = $0.drain() }
                }
                feeds.forEach { $0.input.markAsFinished() }
                writer.endSession(atSourceTime: end)
                writer.finishWriting { [self] in
                    if writer.status == .completed {
                        continuation.resume(returning: Outcome(url: url, error: failure))
                    } else {
                        continuation.resume(returning: Outcome(url: nil, error: .writerFailed(writer.error)))
                    }
                }
            }
        }
    }

    private func push(_ sample: CMSampleBuffer, to feed: Feed) {
        guard failure == nil else { return }
        feed.backlog.append(sample)
        if !feed.drain() {
            fail(.writerFailed(writer.error))
        } else if feed.backlog.count > Feed.limit {
            fail(.overloaded)
        }
    }

    private func fail(_ error: RecordingError) {
        guard failure == nil else { return }
        failure = error
        onFailure(error)
    }

    private static func retimed(_ sample: CMSampleBuffer, duration: CMTime) -> CMSampleBuffer {
        var timing = CMSampleTimingInfo(
            duration: duration,
            presentationTimeStamp: sample.presentationTimeStamp,
            decodeTimeStamp: sample.decodeTimeStamp
        )
        var copy: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(
            allocator: nil, sampleBuffer: sample, sampleTimingEntryCount: 1,
            sampleTimingArray: &timing, sampleBufferOut: &copy
        )
        return copy ?? sample
    }
}

/// One writer input and the samples it had no room for yet.
private final class Feed {
    /// Far more than a hiccup; beyond it the disk is not keeping up.
    static let limit = 600

    let input: AVAssetWriterInput
    var backlog: [CMSampleBuffer] = []

    init(_ input: AVAssetWriterInput) {
        self.input = input
    }

    /// False when the writer refused a sample.
    func drain() -> Bool {
        while let next = backlog.first, input.isReadyForMoreMediaData {
            guard input.append(next) else { return false }
            backlog.removeFirst()
        }
        return true
    }
}

/// Audio sources of one format, laid out gaplessly on the recording's
/// timeline as they arrive: buffers are placed back to back, holes larger
/// than 20 ms are filled with silence, and a source that stops delivering is
/// padded so it cannot hold the others back. What all sources have reached
/// is written out, per source and as their sum.
private final class AudioGroup {
    struct Lane {
        let track: AudioTrack
        /// The source's own track; `nil` when only the mix is kept.
        let stem: Feed?
        /// Frames placed so far, counted from the start of the recording.
        var cursor = 0
        /// Interleaved samples from `flushed` on.
        var pending: [Int16] = []
    }

    private let format: CMAudioFormatDescription
    private let rate: Int
    private let channels: Int
    private var lanes: [Lane]
    private let mix: Feed?
    private var flushed = 0

    init(format: CMAudioFormatDescription, lanes: [Lane], mix: Feed?) {
        let description = format.audioStreamBasicDescription
        self.format = format
        rate = Int(description?.mSampleRate ?? 48_000)
        channels = Int(description?.mChannelsPerFrame ?? 2)
        self.lanes = lanes
        self.mix = mix
    }

    private func frame(_ time: CMTime, from start: CMTime) -> Int {
        Int(CMTimeConvertScale(time - start, timescale: CMTimeScale(rate), method: .default).value)
    }

    func append(_ sample: CMSampleBuffer, from track: AudioTrack, start: CMTime) {
        guard let index = lanes.firstIndex(where: { $0.track == track }),
              let sampleFormat = sample.formatDescription,
              CMFormatDescriptionEqual(sampleFormat, otherFormatDescription: format) else { return }
        let frames = sample.numSamples
        var position = frame(sample.presentationTimeStamp, from: start)
        // The first buffer usually straddles the start of the recording.
        let skipped = max(0, flushed - position, lanes[index].cursor == 0 ? -position : 0)
        guard skipped < frames else { return }
        position += skipped

        let isFirst = lanes[index].cursor == 0
        if position - lanes[index].cursor > (isFirst ? 0 : rate / 50) {
            fill(index, to: position)
        }
        var pointer: UnsafeMutablePointer<CChar>?
        guard let block = sample.dataBuffer, block.dataLength >= frames * channels * 2,
              CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: nil, dataPointerOut: &pointer) == noErr,
              let pointer else { return }
        pointer.withMemoryRebound(to: Int16.self, capacity: frames * channels) { input in
            lanes[index].pending.append(contentsOf: UnsafeBufferPointer(start: input + skipped * channels, count: (frames - skipped) * channels))
        }
        lanes[index].cursor += frames - skipped
    }

    func pad(to end: CMTime, start: CMTime) {
        let last = frame(end, from: start)
        for index in lanes.indices { fill(index, to: last) }
    }

    /// The buffers that are ready to be written, each with the feed it goes to.
    func flush(start: CMTime, final: Bool) -> [(CMSampleBuffer, Feed)] {
        let top = lanes.map(\.cursor).max() ?? 0
        if !final {
            for index in lanes.indices where top - lanes[index].cursor > rate / 2 {
                fill(index, to: top - rate / 4)
            }
        }
        let target = lanes.map(\.cursor).min() ?? 0
        let count = target - flushed
        guard count >= (final ? 1 : 2048) else { return [] }

        let time = start + CMTime(value: CMTimeValue(flushed), timescale: CMTimeScale(rate))
        let length = count * channels
        var result: [(CMSampleBuffer, Feed)] = []
        var sum = [Int32](repeating: 0, count: mix == nil ? 0 : length)
        for index in lanes.indices {
            let lane = lanes[index]
            lane.pending.withUnsafeBufferPointer { samples in
                if mix != nil {
                    for i in 0..<length { sum[i] += Int32(samples[i]) }
                }
                if let stem = lane.stem,
                   let buffer = AudioPipeline.makeBuffer(format: format, frames: count, time: time, fill: { out in
                       for i in 0..<length { out[i] = samples[i] }
                   }) {
                    result.append((buffer, stem))
                }
            }
            lanes[index].pending.removeFirst(length)
        }
        if let mix, let buffer = AudioPipeline.makeBuffer(format: format, frames: count, time: time, fill: { out in
            for i in 0..<length { out[i] = Int16(clamping: sum[i]) }
        }) {
            // The mix is the first audio track, so it is handed over first.
            result.insert((buffer, mix), at: 0)
        }
        flushed = target
        return result
    }

    private func fill(_ index: Int, to position: Int) {
        let missing = position - lanes[index].cursor
        guard missing > 0 else { return }
        lanes[index].pending.append(contentsOf: repeatElement(0, count: missing * channels))
        lanes[index].cursor = position
    }
}
