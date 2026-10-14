import AVFoundation

/// Cuts a time range out of a clip into a new file next to it; the original
/// is never touched.
enum ClipTrimmer {
    enum Mode {
        /// Copies the encoded samples: instant and lossless.
        case passthrough
        /// Re-encodes, so the file holds exactly the chosen range.
        case reencode
    }

    enum TrimError: LocalizedError {
        case unsupported
        case directoryUnavailable(String)
        case diskFull
        case failed(Error?)

        var errorDescription: String? {
            switch self {
            case .unsupported: return String(localized: "This clip can't be trimmed")
            case .directoryUnavailable(let path): return String(localized: "Can't write to the save folder: \(path)")
            case .diskFull: return String(localized: "Disk full, the trimmed clip wasn't saved")
            case .failed(let error): return error?.localizedDescription ?? String(localized: "Couldn't write the trimmed clip")
            }
        }
    }

    /// `progress` gets 0...1 while the export runs. Cancelling the task stops
    /// the export, removes the partial file and throws `CancellationError`.
    static func trim(
        _ source: URL,
        range: CMTimeRange,
        mode: Mode,
        progress: @escaping @MainActor (Double) -> Void
    ) async throws -> URL {
        let asset = AVURLAsset(url: source, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let preset = mode == .passthrough ? AVAssetExportPresetPassthrough : AVAssetExportPresetHighestQuality
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw TrimError.unsupported
        }
        let output = outputURL(for: source)
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
        case .completed:
            return output
        case .cancelled:
            try? FileManager.default.removeItem(at: output)
            throw CancellationError()
        default:
            try? FileManager.default.removeItem(at: output)
            throw classify(session.error, directory: output.deletingLastPathComponent())
        }
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
