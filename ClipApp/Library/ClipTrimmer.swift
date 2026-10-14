import AVFoundation

/// Cuts a time range out of a clip into a new file next to it; the original
/// is never touched.
enum ClipTrimmer {
    enum Mode {
        /// Copies the encoded samples: instant and lossless.
        case passthrough
        /// Re-encodes the video at the source's bitrate, so the file holds
        /// exactly the chosen range.
        case reencode
    }

    /// New levels for the two sources of a clip that carries them as separate
    /// tracks: linear gains, 0 is muted, 1 is as recorded.
    struct AudioEdit: Equatable {
        var system = 1.0
        var microphone = 1.0
    }

    enum TrimError: LocalizedError {
        case unsupported
        case directoryUnavailable(String)
        case diskFull
        case failed(Error?)

        var errorDescription: String? {
            switch self {
            case .unsupported: return AppLanguage.string("This clip can't be trimmed")
            case .directoryUnavailable(let path): return AppLanguage.string("Can't write to the save folder: \(path)")
            case .diskFull: return AppLanguage.string("Disk full, the trimmed clip wasn't saved")
            case .failed(let error): return error?.localizedDescription ?? AppLanguage.string("Couldn't write the trimmed clip")
            }
        }
    }

    /// With `audio` the mixed track is made again from the two source tracks
    /// at the given levels; the source tracks themselves are copied, so the
    /// edit can be redone later. `progress` gets 0...1 while the clip is
    /// written. Cancelling the task stops it, removes the partial file and
    /// throws `CancellationError`.
    static func trim(
        _ source: URL,
        range: CMTimeRange,
        mode: Mode,
        audio: AudioEdit? = nil,
        isFullLength: Bool = false,
        progress: @escaping @MainActor (Double) -> Void
    ) async throws -> URL {
        let asset = AVURLAsset(url: source, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let output = outputURL(for: source, suffix: isFullLength ? "edited" : "trimmed")
        do {
            // An export session copies samples but ignores an audio mix
            // (measured), so anything beyond a plain cut goes through the
            // reader and writer.
            if mode == .passthrough, audio == nil {
                try await copy(asset, range: range, to: output, progress: progress)
            } else {
                try await rewrite(asset, range: range, reencodesVideo: mode == .reencode, audio: audio, to: output, progress: progress)
            }
        } catch {
            try? FileManager.default.removeItem(at: output)
            if error is CancellationError || error is TrimError { throw error }
            throw classify(error, directory: output.deletingLastPathComponent())
        }
        return output
    }

    // MARK: - Passthrough

    private static func copy(
        _ asset: AVURLAsset,
        range: CMTimeRange,
        to output: URL,
        progress: @escaping @MainActor (Double) -> Void
    ) async throws {
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw TrimError.unsupported
        }
        session.outputURL = output
        session.outputFileType = .mp4
        session.timeRange = range

        let reporter = Task { @MainActor in
            while !Task.isCancelled {
                progress(Double(session.progress))
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        await withTaskCancellationHandler {
            await session.export()
        } onCancel: {
            session.cancelExport()
        }
        reporter.cancel()

        switch session.status {
        case .completed: return
        case .cancelled: throw CancellationError()
        default: throw classify(session.error, directory: output.deletingLastPathComponent())
        }
    }

    // MARK: - Re-encode

    /// Set from the cancellation handler, read on the writer queues.
    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false

        var isSet: Bool {
            lock.lock()
            defer { lock.unlock() }
            return value
        }

        func set() {
            lock.lock()
            value = true
            lock.unlock()
        }
    }

    /// One track's way through the trim; only touched on its pump's queue.
    private struct Lane: @unchecked Sendable {
        let output: AVAssetReaderOutput
        let input: AVAssetWriterInput
    }

    /// Reads the range and writes it again. The video is either copied (the
    /// reader then also delivers the frames back to the previous keyframe,
    /// marked as not to be displayed) or decoded and encoded as H.264 at the
    /// source's own bitrate, size and frame timing; export presets pick
    /// their own bitrate (15 Mbps for a 40 Mbps 1080p60 clip). Audio tracks
    /// are copied as they are, and with `audio` a new mix is put in front of
    /// the two source tracks.
    private static func rewrite(
        _ asset: AVURLAsset,
        range: CMTimeRange,
        reencodesVideo: Bool,
        audio: AudioEdit?,
        to output: URL,
        progress: @escaping @MainActor (Double) -> Void
    ) async throws {
        guard let video = try await asset.loadTracks(withMediaType: .video).first else {
            throw TrimError.unsupported
        }
        let (size, transform, dataRate, frameRate, formats) = try await video.load(
            .naturalSize, .preferredTransform, .estimatedDataRate, .nominalFrameRate, .formatDescriptions
        )
        guard dataRate > 0, size.width > 0, size.height > 0 else { throw TrimError.unsupported }

        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = range
        let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
        // Carries the clip's own record (game, time) over, see `ClipInfo`.
        writer.metadata = try await asset.load(.metadata)

        let videoOutput: AVAssetReaderTrackOutput
        let videoInput: AVAssetWriterInput
        if reencodesVideo {
            var compression: [String: Any] = [
                AVVideoAverageBitRateKey: Int(dataRate),
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoMaxKeyFrameIntervalDurationKey: 2,
            ]
            if frameRate > 0 { compression[AVVideoExpectedSourceFrameRateKey] = Int(frameRate.rounded()) }
            var settings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: Int(size.width),
                AVVideoHeightKey: Int(size.height),
                AVVideoCompressionPropertiesKey: compression,
            ]
            if let color = formats.first.flatMap(colorProperties) { settings[AVVideoColorPropertiesKey] = color }
            videoOutput = AVAssetReaderTrackOutput(
                track: video,
                outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
            )
            videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        } else {
            videoOutput = AVAssetReaderTrackOutput(track: video, outputSettings: nil)
            videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: formats.first)
        }
        videoOutput.alwaysCopiesSampleData = false
        videoInput.transform = transform
        videoInput.expectsMediaDataInRealTime = false
        guard reader.canAdd(videoOutput), writer.canAdd(videoInput) else { throw TrimError.unsupported }
        reader.add(videoOutput)
        writer.add(videoInput)
        var lanes = [Lane(output: videoOutput, input: videoInput)]
        var readers = [reader]

        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        var copied = audioTracks
        if let audio {
            // The mix comes from the two source tracks, read a second time
            // through their own reader, and goes in as the first audio track.
            guard var info = await ClipInfo.read(from: asset), let roles = info.audio, roles.count == audioTracks.count,
                  let system = roles.firstIndex(of: .system), let microphone = roles.firstIndex(of: .microphone),
                  let description = try await audioTracks[system].load(.formatDescriptions).first?.audioStreamBasicDescription
            else { throw TrimError.unsupported }
            copied = [audioTracks[system], audioTracks[microphone]]

            let mix = AVMutableAudioMix()
            mix.inputParameters = zip(copied, [audio.system, audio.microphone]).map { track, level in
                let parameters = AVMutableAudioMixInputParameters(track: track)
                parameters.setVolume(Float(level), at: .zero)
                return parameters
            }
            let mixOutput = AVAssetReaderAudioMixOutput(audioTracks: copied, audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
                AVSampleRateKey: description.mSampleRate,
                AVNumberOfChannelsKey: 2,
            ])
            mixOutput.audioMix = mix
            mixOutput.alwaysCopiesSampleData = false
            var settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: description.mSampleRate,
                AVNumberOfChannelsKey: 2,
            ]
            if description.mSampleRate >= 44_100 { settings[AVEncoderBitRateKey] = 192_000 }
            let mixInput = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
            mixInput.expectsMediaDataInRealTime = false
            let mixReader = try AVAssetReader(asset: asset)
            mixReader.timeRange = range
            guard mixReader.canAdd(mixOutput), writer.canAdd(mixInput) else { throw TrimError.unsupported }
            mixReader.add(mixOutput)
            writer.add(mixInput)
            lanes.append(Lane(output: mixOutput, input: mixInput))
            readers.append(mixReader)

            info.audio = [.mix, .system, .microphone]
            info.levels = [ClipInfo.AudioRole.system.rawValue: audio.system, ClipInfo.AudioRole.microphone.rawValue: audio.microphone]
            writer.metadata = info.metadataItems
        }

        for track in copied {
            let audioOutput = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            audioOutput.alwaysCopiesSampleData = false
            let audioInput = AVAssetWriterInput(
                mediaType: .audio,
                outputSettings: nil,
                sourceFormatHint: try await track.load(.formatDescriptions).first
            )
            audioInput.expectsMediaDataInRealTime = false
            // Beside a new mix the source tracks are the disabled ones;
            // otherwise each track keeps the state it had.
            audioInput.marksOutputTrackAsEnabled = audio == nil ? try await track.load(.isEnabled) : false
            guard reader.canAdd(audioOutput), writer.canAdd(audioInput) else { continue }
            reader.add(audioOutput)
            writer.add(audioInput)
            lanes.append(Lane(output: audioOutput, input: audioInput))
        }

        for reader in readers {
            guard reader.startReading() else { throw classify(reader.error, directory: output.deletingLastPathComponent()) }
        }
        guard writer.startWriting() else { throw classify(writer.error, directory: output.deletingLastPathComponent()) }
        writer.startSession(atSourceTime: range.start)

        let cancelled = Flag()
        let seconds = max(range.duration.seconds, 0.001)
        await withTaskCancellationHandler {
            await withTaskGroup(of: Void.self) { group in
                for (index, lane) in lanes.enumerated() {
                    group.addTask {
                        await pump(lane, cancelled: cancelled) { time in
                            // Markers between edits carry no time.
                            guard index == 0, time.isNumeric else { return }
                            let fraction = min(max(0, (time - range.start).seconds / seconds), 1)
                            Task { @MainActor in progress(fraction) }
                        }
                    }
                }
            }
        } onCancel: {
            cancelled.set()
        }

        if cancelled.isSet {
            readers.forEach { $0.cancelReading() }
            writer.cancelWriting()
            throw CancellationError()
        }
        if let failed = readers.first(where: { $0.status != .completed }) {
            writer.cancelWriting()
            throw classify(failed.error ?? writer.error, directory: output.deletingLastPathComponent())
        }
        writer.endSession(atSourceTime: range.end)
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw classify(writer.error, directory: output.deletingLastPathComponent())
        }
    }

    /// Moves samples from the reader output to the writer input until the
    /// output runs dry, the writer refuses a sample or the trim is cancelled.
    private static func pump(
        _ lane: Lane,
        cancelled: Flag,
        onSample: @escaping (CMTime) -> Void
    ) async {
        let queue = DispatchQueue(label: "com.mertozturk.ClipApp.trim", qos: .userInitiated)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lane.input.requestMediaDataWhenReady(on: queue) {
                while lane.input.isReadyForMoreMediaData {
                    guard !cancelled.isSet, let sample = lane.output.copyNextSampleBuffer(),
                          lane.input.append(sample) else {
                        lane.input.markAsFinished()
                        continuation.resume()
                        return
                    }
                    onSample(sample.presentationTimeStamp)
                }
            }
        }
    }

    /// Carries the source's color tags over; without them the encoder guesses.
    private static func colorProperties(_ format: CMFormatDescription) -> [String: Any]? {
        guard let extensions = CMFormatDescriptionGetExtensions(format) as? [CFString: Any],
              let primaries = extensions[kCMFormatDescriptionExtension_ColorPrimaries],
              let transfer = extensions[kCMFormatDescriptionExtension_TransferFunction],
              let matrix = extensions[kCMFormatDescriptionExtension_YCbCrMatrix] else { return nil }
        return [
            AVVideoColorPrimariesKey: primaries,
            AVVideoTransferFunctionKey: transfer,
            AVVideoYCbCrMatrixKey: matrix,
        ]
    }

    /// `<name> (trimmed).mp4`, then `(trimmed 2)`, `(trimmed 3)`…
    private static func outputURL(for source: URL, suffix: String) -> URL {
        let directory = source.deletingLastPathComponent()
        let name = source.deletingPathExtension().lastPathComponent
        var candidate = directory.appendingPathComponent("\(name) (\(suffix))").appendingPathExtension("mp4")
        var index = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(name) (\(suffix) \(index))").appendingPathExtension("mp4")
            index += 1
        }
        return candidate
    }

    private static func classify(_ error: Error?, directory: URL) -> TrimError {
        var codes: [(String, Int)] = []
        var current = error as NSError?
        while let nsError = current {
            codes.append((nsError.domain, nsError.code))
            current = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        let isDiskFull = codes.contains {
            $0 == (AVFoundationErrorDomain, AVError.diskFull.rawValue)
                || $0 == (NSCocoaErrorDomain, NSFileWriteOutOfSpaceError)
                || $0 == (NSPOSIXErrorDomain, Int(ENOSPC))
        }
        if isDiskFull { return .diskFull }
        if !FileManager.default.isWritableFile(atPath: directory.path) {
            return .directoryUnavailable(directory.path)
        }
        return .failed(error)
    }
}
