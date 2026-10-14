import AVFoundation
import CoreMedia

/// Muxes already-encoded samples into an mp4 without re-encoding.
enum ClipWriter {
    enum WriteError: LocalizedError {
        case emptyBuffer
        case cannotAddInput
        case directoryUnavailable(String)
        case diskFull
        case writerFailed(Error?)

        var errorDescription: String? {
            switch self {
            case .emptyBuffer: return AppLanguage.string("Nothing in the buffer yet")
            case .cannotAddInput: return AppLanguage.string("Couldn't create the video track")
            case .directoryUnavailable(let path): return AppLanguage.string("Can't write to the save folder: \(path)")
            case .diskFull: return AppLanguage.string("Disk full, the clip wasn't saved")
            case .writerFailed(let error): return error?.localizedDescription ?? AppLanguage.string("Couldn't write the clip")
            }
        }
    }

    private static let queue = DispatchQueue(label: "com.mertozturk.ClipApp.clipwriter", qos: .userInitiated)

    /// `mixAudio` puts all audio sources into one track instead of one each.
    /// `info` is stored in the file, see `ClipInfo`.
    static func write(
        _ snapshot: RingBuffer.Snapshot,
        to directory: URL,
        name: String,
        mixAudio: Bool,
        info: ClipInfo
    ) async throws -> URL {
        guard let first = snapshot.video.first, let format = first.formatDescription else {
            throw WriteError.emptyBuffer
        }
        // A deleted folder is simply recreated; anything else (read-only,
        // unmounted volume, a file in the way) is reported with the path.
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw WriteError.directoryUnavailable(directory.path)
        }
        guard FileManager.default.isWritableFile(atPath: directory.path) else {
            throw WriteError.directoryUnavailable(directory.path)
        }
        let url = uniqueURL(in: directory, name: name)

        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        } catch {
            throw WriteError.writerFailed(error)
        }
        writer.shouldOptimizeForNetworkUse = true
        writer.metadata = info.metadataItems
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: format)
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else { throw WriteError.cannotAddInput }
        writer.add(input)

        // Frames at or before the clip start are only there to make the first
        // visible frame decodable. They are slid forward so the last of them
        // lands exactly on the clip start: that frame was what the screen showed
        // at that moment, however long ago it was captured. Without this a
        // static screen would leave an arbitrarily long lead-in, or no frame at
        // all inside the clip.
        let leadInCount = snapshot.video.prefix { $0.presentationTimeStamp <= snapshot.startTime }.count
        let leadInShift = snapshot.startTime - snapshot.video[leadInCount - 1].presentationTimeStamp
        // Everything is then rebased so the file starts at zero.
        let base = first.presentationTimeStamp + leadInShift
        // The last frame is stretched to the moment the clip was requested, so
        // the video track is as long as the clip even when the screen stood still.
        let lastIndex = snapshot.video.count - 1
        let samples = snapshot.video.enumerated().compactMap { index, sample in
            rebase(
                sample,
                by: index < leadInCount ? base - leadInShift : base,
                duration: index == lastIndex ? snapshot.endTime - max(sample.presentationTimeStamp, snapshot.startTime) : nil
            )
        }

        // The session starts at the clip start; the writer keeps the lead-in
        // for decoding and trims it from playback with an edit list.
        let clipStart = snapshot.startTime - base
        let clipEnd = snapshot.endTime - base
        var pumps = [SamplePump(writer: writer, input: input, samples: samples)]

        var audio: [(format: CMAudioFormatDescription, samples: [CMSampleBuffer])] = AudioTrack.allCases.compactMap { track in
            guard let captured = snapshot.audio[track], let format = captured.first?.formatDescription else { return nil }
            return (format, audioTimeline(captured, format: format, base: base, from: clipStart, to: clipEnd))
        }
        // Sources at different sample rates cannot be added up; they stay separate.
        if mixAudio, audio.count > 1,
           audio.dropFirst().allSatisfy({ CMFormatDescriptionEqual($0.format, otherFormatDescription: audio[0].format) }) {
            audio = [(audio[0].format, mix(audio.map(\.samples), format: audio[0].format))]
        }

        // One AAC track per entry. A track the writer cannot take is left out
        // rather than failing the whole clip.
        for (format, timeline) in audio {
            guard let description = format.audioStreamBasicDescription else { continue }
            var settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: description.mSampleRate,
                AVNumberOfChannelsKey: Int(description.mChannelsPerFrame),
            ]
            // Low rates (Bluetooth headset microphones) only allow low bitrates;
            // the encoder picks its own there.
            if description.mSampleRate >= 44_100 {
                settings[AVEncoderBitRateKey] = 96_000 * Int(description.mChannelsPerFrame)
            }
            guard writer.canApply(outputSettings: settings, forMediaType: .audio) else { continue }
            let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: settings, sourceFormatHint: format)
            audioInput.expectsMediaDataInRealTime = false
            guard writer.canAdd(audioInput) else { continue }
            writer.add(audioInput)
            pumps.append(SamplePump(writer: writer, input: audioInput, samples: timeline))
        }

        guard writer.startWriting() else { throw WriteError.writerFailed(writer.error) }
        writer.startSession(atSourceTime: clipStart)
        // All tracks are fed together: the writer interleaves them and stops
        // asking one input for data while another lags behind.
        await withTaskGroup(of: Void.self) { group in
            for pump in pumps {
                group.addTask { await pump.run(on: queue) }
            }
        }

        if writer.status == .writing {
            writer.endSession(atSourceTime: clipEnd)
            await writer.finishWriting()
        }
        guard writer.status == .completed else {
            let error = writer.error
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            throw isDiskFull(error) ? WriteError.diskFull : WriteError.writerFailed(error)
        }
        return url
    }

    /// Lays captured PCM out as one gapless run covering the whole clip, on
    /// the clip's zero-based timeline. Capture timestamps jitter by a few
    /// samples and can have holes (stream restart, source enabled mid-buffer);
    /// the AAC encoder wants neither, so buffers are placed back to back and
    /// real holes, including the ones before the first and after the last
    /// buffer, are filled with silence.
    private static func audioTimeline(
        _ captured: [CMSampleBuffer],
        format: CMAudioFormatDescription,
        base: CMTime,
        from clipStart: CMTime,
        to clipEnd: CMTime
    ) -> [CMSampleBuffer] {
        guard let sampleRate = format.audioStreamBasicDescription?.mSampleRate, let first = captured.first else { return [] }
        let scale = CMTimeScale(sampleRate)
        let tolerance = CMTime(value: CMTimeValue(scale / 50), timescale: scale)
        func frames(_ time: CMTime) -> CMTimeValue { CMTimeConvertScale(time, timescale: scale, method: .default).value }

        var timeline: [CMSampleBuffer] = []
        // The first buffer usually begins slightly before the clip does.
        var cursor = CMTime(value: min(frames(clipStart), frames(first.presentationTimeStamp - base)), timescale: scale)
        func fillSilence(until time: CMTime) {
            let missing = Int(frames(time) - cursor.value)
            guard missing > 0, let silence = AudioPipeline.makeBuffer(format: format, frames: missing, time: cursor) else { return }
            timeline.append(silence)
            cursor.value += CMTimeValue(missing)
        }
        for sample in captured {
            let time = sample.presentationTimeStamp - base
            if time - cursor > tolerance { fillSilence(until: time) }
            // An overlap is not cut; the buffer just moves to the end of the run.
            var timing = CMSampleTimingInfo(
                duration: CMTime(value: 1, timescale: scale),
                presentationTimeStamp: cursor,
                decodeTimeStamp: .invalid
            )
            var placed: CMSampleBuffer?
            CMSampleBufferCreateCopyWithNewTiming(
                allocator: nil, sampleBuffer: sample, sampleTimingEntryCount: 1,
                sampleTimingArray: &timing, sampleBufferOut: &placed
            )
            guard let placed else { continue }
            timeline.append(placed)
            cursor.value += CMTimeValue(sample.numSamples)
        }
        fillSilence(until: clipEnd)
        return timeline
    }

    /// Adds gapless timelines of the same format into one. Sums are clipped.
    private static func mix(_ timelines: [[CMSampleBuffer]], format: CMAudioFormatDescription) -> [CMSampleBuffer] {
        let buffers = timelines.joined()
        guard let description = format.audioStreamBasicDescription,
              let start = buffers.map(\.presentationTimeStamp.value).min(),
              let end = buffers.map({ $0.presentationTimeStamp.value + CMTimeValue($0.numSamples) }).max()
        else { return timelines.first ?? [] }
        let scale = CMTimeScale(description.mSampleRate)
        let channels = Int(description.mChannelsPerFrame)
        let frames = Int(end - start)

        var mixed = [Int16](repeating: 0, count: frames * channels)
        for buffer in buffers {
            let offset = Int(buffer.presentationTimeStamp.value - start) * channels
            let count = buffer.numSamples * channels
            var pointer: UnsafeMutablePointer<CChar>?
            guard let block = buffer.dataBuffer, block.dataLength >= count * 2,
                  CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: nil, dataPointerOut: &pointer) == noErr,
                  let pointer else { continue }
            pointer.withMemoryRebound(to: Int16.self, capacity: count) { input in
                for i in 0..<count {
                    mixed[offset + i] = Int16(clamping: Int32(mixed[offset + i]) + Int32(input[i]))
                }
            }
        }

        // Handed to the writer a second at a time.
        return stride(from: 0, to: frames, by: Int(scale)).compactMap { frame in
            let count = min(Int(scale), frames - frame)
            return AudioPipeline.makeBuffer(
                format: format, frames: count, time: CMTime(value: start + CMTimeValue(frame), timescale: scale)
            ) { out in
                for i in 0..<count * channels { out[i] = mixed[frame * channels + i] }
            }
        }
    }

    private static func isDiskFull(_ error: Error?) -> Bool {
        var current = error as NSError?
        while let nsError = current {
            if nsError.domain == AVFoundationErrorDomain, nsError.code == AVError.diskFull.rawValue { return true }
            if nsError.domain == NSPOSIXErrorDomain, nsError.code == Int(ENOSPC) { return true }
            if nsError.domain == NSCocoaErrorDomain, nsError.code == NSFileWriteOutOfSpaceError { return true }
            current = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return false
    }

    private static func rebase(_ sample: CMSampleBuffer, by base: CMTime, duration: CMTime? = nil) -> CMSampleBuffer? {
        var count: CMItemCount = 0
        CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
        var timing = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
        CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: count, arrayToFill: &timing, entriesNeededOut: &count)
        for i in timing.indices {
            timing[i].presentationTimeStamp = timing[i].presentationTimeStamp - base
            if timing[i].decodeTimeStamp.isValid {
                timing[i].decodeTimeStamp = timing[i].decodeTimeStamp - base
            }
            if let duration, duration > .zero {
                timing[i].duration = duration
            }
        }
        var rebased: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(
            allocator: nil,
            sampleBuffer: sample,
            sampleTimingEntryCount: count,
            sampleTimingArray: &timing,
            sampleBufferOut: &rebased
        )
        return rebased
    }

    private static func uniqueURL(in directory: URL, name: String) -> URL {
        var url = directory.appendingPathComponent("\(name).mp4")
        var suffix = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = directory.appendingPathComponent("\(name)_\(suffix).mp4")
            suffix += 1
        }
        return url
    }
}

/// Feeds samples to the writer as it asks for them. Mutable state is only
/// touched on the queue passed to `run(on:)`.
private final class SamplePump: @unchecked Sendable {
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let samples: [CMSampleBuffer]
    private var index = 0

    init(writer: AVAssetWriter, input: AVAssetWriterInput, samples: [CMSampleBuffer]) {
        self.writer = writer
        self.input = input
        self.samples = samples
    }

    func run(on queue: DispatchQueue) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            input.requestMediaDataWhenReady(on: queue) { [self] in
                while input.isReadyForMoreMediaData {
                    guard index < samples.count, writer.status == .writing else {
                        input.markAsFinished()
                        continuation.resume()
                        return
                    }
                    let sample = samples[index]
                    index += 1
                    if !input.append(sample) {
                        input.markAsFinished()
                        continuation.resume()
                        return
                    }
                }
            }
        }
    }
}
