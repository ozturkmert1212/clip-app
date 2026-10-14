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

    /// `progress` gets 0...1 while the clip is written. Cancelling the task
    /// stops it, removes the partial file and throws `CancellationError`.
    static func trim(
        _ source: URL,
        range: CMTimeRange,
        mode: Mode,
        progress: @escaping @MainActor (Double) -> Void
    ) async throws -> URL {
        let asset = AVURLAsset(url: source, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let output = outputURL(for: source)
        do {
            switch mode {
            case .passthrough: try await copy(asset, range: range, to: output, progress: progress)
            case .reencode: try await reencode(asset, range: range, to: output, progress: progress)
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

    /// Decodes the range and encodes it again as H.264 at the source's own
    /// bitrate, size and frame timing. Export presets pick their own bitrate
    /// (15 Mbps for a 40 Mbps 1080p60 clip), hence reader and writer. Audio
    /// is copied as it is, track by track.
    private static func reencode(
        _ asset: AVURLAsset,
        range: CMTimeRange,
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

        let videoOutput = AVAssetReaderTrackOutput(
            track: video,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
        )
        videoOutput.alwaysCopiesSampleData = false
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        videoInput.transform = transform
        videoInput.expectsMediaDataInRealTime = false
        guard reader.canAdd(videoOutput), writer.canAdd(videoInput) else { throw TrimError.unsupported }
        reader.add(videoOutput)
        writer.add(videoInput)
        var lanes = [Lane(output: videoOutput, input: videoInput)]

        for track in try await asset.loadTracks(withMediaType: .audio) {
            let audioOutput = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            audioOutput.alwaysCopiesSampleData = false
            let audioInput = AVAssetWriterInput(
                mediaType: .audio,
                outputSettings: nil,
                sourceFormatHint: try await track.load(.formatDescriptions).first
            )
            audioInput.expectsMediaDataInRealTime = false
            guard reader.canAdd(audioOutput), writer.canAdd(audioInput) else { continue }
            reader.add(audioOutput)
            writer.add(audioInput)
            lanes.append(Lane(output: audioOutput, input: audioInput))
        }

        guard reader.startReading() else { throw classify(reader.error, directory: output.deletingLastPathComponent()) }
        guard writer.startWriting() else { throw classify(writer.error, directory: output.deletingLastPathComponent()) }
        writer.startSession(atSourceTime: range.start)

        let cancelled = Flag()
        let seconds = max(range.duration.seconds, 0.001)
        await withTaskCancellationHandler {
            await withTaskGroup(of: Void.self) { group in
                for (index, lane) in lanes.enumerated() {
                    group.addTask {
                        await pump(lane, cancelled: cancelled) { time in
                            guard index == 0 else { return }
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
            reader.cancelReading()
            writer.cancelWriting()
            throw CancellationError()
        }
        guard reader.status == .completed else {
            writer.cancelWriting()
            throw classify(reader.error ?? writer.error, directory: output.deletingLastPathComponent())
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
    private static func outputURL(for source: URL) -> URL {
        let directory = source.deletingLastPathComponent()
        let name = source.deletingPathExtension().lastPathComponent
        var candidate = directory.appendingPathComponent("\(name) (trimmed)").appendingPathExtension("mp4")
        var index = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(name) (trimmed \(index))").appendingPathExtension("mp4")
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
