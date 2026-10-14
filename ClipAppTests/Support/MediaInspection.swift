import AVFoundation
import XCTest

/// What the media tests read back from a written file, with AVFoundation only.
struct MediaFile {
    let url: URL
    let asset: AVURLAsset

    init(_ url: URL) {
        self.url = url
        asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
    }

    func duration() async throws -> Double { try await asset.load(.duration).seconds }

    func videoTrack() async throws -> AVAssetTrack {
        let tracks = try await asset.loadTracks(withMediaType: .video)
        return try XCTUnwrap(tracks.first)
    }

    func audioTracks() async throws -> [AVAssetTrack] { try await asset.loadTracks(withMediaType: .audio) }

    func audioEnabled() async throws -> [Bool] {
        var flags: [Bool] = []
        for track in try await audioTracks() { flags.append(try await track.load(.isEnabled)) }
        return flags
    }

    func info() async -> ClipInfo? { await ClipInfo.read(from: asset) }

    /// Every video sample stored in the file, including ones an edit list
    /// keeps out of playback.
    func storedVideoFrames() async throws -> Int {
        let track = try await videoTrack()
        let cursor = try XCTUnwrap(track.makeSampleCursorAtFirstSampleInDecodeOrder())
        var count = 1
        while cursor.stepInDecodeOrder(byCount: 1) == 1 { count += 1 }
        return count
    }

    func videoCodec() async throws -> CMVideoCodecType {
        let formats = try await videoTrack().load(.formatDescriptions)
        return CMFormatDescriptionGetMediaSubType(try XCTUnwrap(formats.first))
    }

    /// The first channel of audio track `index` (0 = first audio track) as
    /// played, i.e. with the track's edits applied, between `from` and `to`.
    func samples(ofAudioTrack index: Int, from: Double = 0, to: Double? = nil) async throws -> (samples: [Float], rate: Double) {
        let track = try await audioTracks()[index]
        let formats = try await track.load(.formatDescriptions)
        let description = try XCTUnwrap(formats.first?.audioStreamBasicDescription)
        let reader = try AVAssetReader(asset: asset)
        let end = try await asset.load(.duration).seconds
        reader.timeRange = CMTimeRange(
            start: CMTime(seconds: from, preferredTimescale: 48_000),
            end: CMTime(seconds: min(to ?? end, end), preferredTimescale: 48_000)
        )
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        reader.add(output)
        XCTAssertTrue(reader.startReading(), "\(String(describing: reader.error))")
        let channels = max(1, Int(description.mChannelsPerFrame))
        var samples: [Float] = []
        while let buffer = output.copyNextSampleBuffer() {
            var pointer: UnsafeMutablePointer<CChar>?
            var length = 0
            guard let block = buffer.dataBuffer,
                  CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer) == noErr,
                  let pointer else { continue }
            let frames = length / (4 * channels)
            pointer.withMemoryRebound(to: Float.self, capacity: frames * channels) { data in
                for frame in 0..<frames { samples.append(data[frame * channels]) }
            }
        }
        XCTAssertEqual(reader.status, .completed, "\(String(describing: reader.error))")
        return (samples, description.mSampleRate)
    }

    /// Level in dB relative to full scale of the `hz` component of an audio track.
    func level(of hz: Double, inAudioTrack index: Int, from: Double = 0, to: Double? = nil) async throws -> Double {
        let (samples, rate) = try await samples(ofAudioTrack: index, from: from, to: to)
        return Goertzel.level(of: hz, in: samples, sampleRate: rate)
    }

    /// Decodes a picture at `seconds`; fails the test if that is not possible.
    func assertDecodes(at seconds: Double, file: StaticString = #filePath, line: UInt = #line) async {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        do {
            let image = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
            XCTAssertGreaterThan(image.width, 0, file: file, line: line)
        } catch {
            XCTFail("No picture at \(seconds) s: \(error)", file: file, line: line)
        }
    }
}

/// Measures one frequency in a signal.
enum Goertzel {
    /// Amplitude of the `hz` component in dB relative to full scale; a sine of
    /// peak 1.0 gives 0 dB. Silence gives a very low number rather than -inf.
    static func level(of hz: Double, in samples: [Float], sampleRate: Double) -> Double {
        guard !samples.isEmpty else { return -200 }
        let coefficient = 2 * cos(2 * .pi * hz / sampleRate)
        var previous = 0.0, beforePrevious = 0.0
        for sample in samples {
            let current = Double(sample) + coefficient * previous - beforePrevious
            beforePrevious = previous
            previous = current
        }
        let power = previous * previous + beforePrevious * beforePrevious - coefficient * previous * beforePrevious
        let amplitude = 2 * power.squareRoot() / Double(samples.count)
        return 20 * log10(max(amplitude, 1e-10))
    }
}
