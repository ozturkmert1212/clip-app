import AVFoundation
import CoreMedia
import CoreVideo
import XCTest

/// Input for the real pipeline that needs no screen and no device: a white
/// bar moving over a busy background as video, a 440 Hz tone as system audio
/// and an 880 Hz tone as microphone.
enum Synthetic {
    static let width = 640
    static let height = 360
    static let fps = 60
    static let bitrate = 4_000_000
    static let sampleRate = 48_000
    static let systemTone = 440.0
    static let microphoneTone = 880.0
    /// Peak of both tones; -12.2 dB relative to full scale.
    static let amplitude = 8000.0
    static var toneLevel: Double { 20 * log10(amplitude / 32768) }

    /// A few frames of fine noise. Cycling through them gives the encoder
    /// about as much to do as a busy game scene, so it spends its bitrate;
    /// flat synthetic pictures compress to almost nothing.
    private static let textures: [[UInt8]] = (0..<6).map { _ in
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        arc4random_buf(&bytes, bytes.count)
        for index in bytes.indices { bytes[index] = index % 4 == 3 ? 255 : 96 + (bytes[index] & 0x3F) }
        return bytes
    }

    static func frame(_ index: Int, at time: CMTime) -> CMSampleBuffer {
        var created: CVPixelBuffer?
        CVPixelBufferCreate(
            nil, width, height, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &created
        )
        let buffer = created!
        CVPixelBufferLockBaseAddress(buffer, [])
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        let bar = (index * 6) % (width - 40)
        textures[index % textures.count].withUnsafeBufferPointer { texture in
            for y in 0..<height {
                memcpy(base + y * stride, texture.baseAddress! + y * width * 4, width * 4)
                memset(base + y * stride + bar * 4, 255, 40 * 4)
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])

        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: buffer, formatDescriptionOut: &format)
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(fps)), presentationTimeStamp: time, decodeTimeStamp: .invalid
        )
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(
            allocator: nil, imageBuffer: buffer, formatDescription: format!, sampleTiming: &timing, sampleBufferOut: &sample
        )
        return sample!
    }

    /// `frames` frames of a sine at `hz` whose phase continues from absolute
    /// frame `start`, timed from `base`.
    static func tone(_ hz: Double, start: Int, frames: Int, base: CMTime) -> CMSampleBuffer {
        let time = base + CMTime(value: CMTimeValue(start), timescale: CMTimeScale(sampleRate))
        return AudioPipeline.makeBuffer(format: FakeSamples.audioFormat, frames: frames, time: time) { out in
            for index in 0..<frames {
                let value = Int16(amplitude * sin(2 * .pi * hz * Double(start + index) / Double(sampleRate)))
                out[index * 2] = value
                out[index * 2 + 1] = value
            }
        }!
    }

    static func frameTime(_ index: Int, from base: CMTime) -> CMTime {
        base + CMTime(value: CMTimeValue(index), timescale: CMTimeScale(fps))
    }

    /// Runs the capture pipeline's own stages on synthetic input and saves
    /// the last `seconds` as a clip: `EncoderPipeline` -> `RingBuffer` ->
    /// `ClipWriter`. More than `seconds` is fed, and the window does not start
    /// on a keyframe, so the clip has the hidden lead-in real clips have.
    static func makeClip(
        in directory: URL,
        name: String = "synthetic",
        seconds: Double = 6,
        microphone: Bool = true,
        keepStems: Bool = true,
        info: ClipInfo = ClipInfo(game: "Test Game", bundleID: "com.example.testgame", recorded: Date())
    ) async throws -> URL {
        let total = seconds + 2.7
        let ring = RingBuffer(duration: seconds, byteLimit: .max)
        let encoder = EncoderPipeline(fps: fps, bitrate: bitrate) { ring.append($0) }
        let end = CMClockGetTime(CMClockGetHostTimeClock())
        let base = end - CMTime(seconds: total, preferredTimescale: 600)

        let frames = Int(total * Double(fps))
        for index in 0..<frames { encoder.encode(frame(index, at: frameTime(index, from: base))) }
        let samples = Int(total * Double(sampleRate))
        // Different buffer sizes, as the two sources have in the app.
        for start in stride(from: 0, to: samples, by: 1024) {
            ring.append(tone(systemTone, start: start, frames: 1024, base: base), to: .system)
        }
        if microphone {
            for start in stride(from: 0, to: samples, by: 480) {
                ring.append(tone(microphoneTone, start: start, frames: 480, base: base), to: .microphone)
            }
        }
        try await waitForEncoder(ring, until: frameTime(frames - 1, from: base))

        let snapshot = try XCTUnwrap(ring.snapshot(endingAt: end))
        return try await ClipWriter.write(snapshot, to: directory, name: name, keepStems: keepStems, info: info)
    }

    /// The encoder hands frames back asynchronously.
    static func waitForEncoder(_ ring: RingBuffer, until last: CMTime) async throws {
        for _ in 0..<500 {
            let status = ring.videoStatus()
            if let oldest = status.oldest, oldest.seconds + status.span >= last.seconds - 0.0005 { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("The encoder did not deliver all frames")
    }
}
