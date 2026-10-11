import CoreMedia
import OSLog

/// Brings captured LPCM to one shape (16-bit interleaved stereo) and applies
/// the track level. Sources that share a sample rate can then be mixed. Audio stays uncompressed in the ring buffer and is
/// encoded to AAC when a clip is written: PCM can be cut and padded per sample,
/// and at 16 bit it is small next to the video.
final class AudioPipeline {
    private let logger = Logger(subsystem: "com.mertozturk.ClipApp", category: "audio")
    private let lock = NSLock()
    private var gain: Float = 1
    private var format: CMAudioFormatDescription?
    private var rejectedFormat: AudioStreamBasicDescription?
    private let onOutput: (CMSampleBuffer) -> Void

    /// `onOutput` runs on whatever queue calls `process`.
    init(onOutput: @escaping (CMSampleBuffer) -> Void) {
        self.onOutput = onOutput
    }

    /// 1 leaves the signal untouched.
    func setGain(_ gain: Float) {
        lock.lock()
        defer { lock.unlock() }
        self.gain = gain
    }

    /// `time` replaces the buffer's own timestamp when that is not on the host clock.
    /// Must not be called concurrently for the same pipeline.
    func process(_ sample: CMSampleBuffer, at time: CMTime? = nil) {
        guard let source = sample.formatDescription?.audioStreamBasicDescription else { return }
        let flags = source.mFormatFlags
        let isFloat = flags & kAudioFormatFlagIsFloat != 0
        let isPlanar = flags & kAudioFormatFlagIsNonInterleaved != 0
        let supported = source.mFormatID == kAudioFormatLinearPCM
            && flags & kAudioFormatFlagIsBigEndian == 0
            && (isFloat ? source.mBitsPerChannel == 32
                : source.mBitsPerChannel == 16 && flags & kAudioFormatFlagIsSignedInteger != 0)
        guard supported else {
            if rejectedFormat?.mFormatFlags != flags || rejectedFormat?.mBitsPerChannel != source.mBitsPerChannel {
                rejectedFormat = source
                logger.error("Unsupported audio format: id \(source.mFormatID) flags \(flags) bits \(source.mBitsPerChannel)")
            }
            return
        }

        let frames = sample.numSamples
        let inputChannels = Int(source.mChannelsPerFrame)
        let channels = 2
        guard frames > 0, inputChannels > 0 else { return }

        lock.lock()
        let gain = self.gain
        lock.unlock()

        let format = outputFormat(sampleRate: source.mSampleRate, channels: channels)
        let output = Self.makeBuffer(format: format, frames: frames, time: time ?? sample.presentationTimeStamp) { out in
            try? sample.withAudioBufferList { list, _ in
                for channel in 0..<channels {
                    // Mono lands on both sides; anything past stereo is dropped.
                    let sourceChannel = min(channel, inputChannels - 1)
                    let index = isPlanar ? sourceChannel : 0
                    guard index < list.count, let data = list[index].mData else { continue }
                    let stride = isPlanar ? 1 : inputChannels
                    let offset = isPlanar ? 0 : sourceChannel
                    guard Int(list[index].mDataByteSize) >= frames * stride * (isFloat ? 4 : 2) else { continue }
                    if isFloat {
                        let input = data.assumingMemoryBound(to: Float32.self)
                        for frame in 0..<frames {
                            let value = input[frame * stride + offset] * gain
                            out[frame * channels + channel] = Int16(max(-1, min(1, value)) * 32767)
                        }
                    } else {
                        let input = data.assumingMemoryBound(to: Int16.self)
                        for frame in 0..<frames {
                            let value = Float(input[frame * stride + offset]) * gain
                            out[frame * channels + channel] = Int16(max(-32767, min(32767, value)))
                        }
                    }
                }
            }
        }
        if let output { onOutput(output) }
    }

    private func outputFormat(sampleRate: Double, channels: Int) -> CMAudioFormatDescription {
        if let format, let current = format.audioStreamBasicDescription,
           current.mSampleRate == sampleRate, Int(current.mChannelsPerFrame) == channels {
            return format
        }
        var description = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(2 * channels),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(2 * channels),
            mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 16,
            mReserved: 0
        )
        var created: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(
            allocator: nil, asbd: &description, layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &created
        )
        format = created
        logger.info("Audio format: \(Int(sampleRate)) Hz, \(channels) ch")
        return created!
    }

    /// A zeroed buffer in `format` (which must be 16-bit PCM), optionally filled by `fill`.
    static func makeBuffer(
        format: CMAudioFormatDescription,
        frames: Int,
        time: CMTime,
        fill: ((UnsafeMutablePointer<Int16>) -> Void)? = nil
    ) -> CMSampleBuffer? {
        guard let description = format.audioStreamBasicDescription, frames > 0 else { return nil }
        let length = frames * Int(description.mBytesPerFrame)
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(
            allocator: nil, memoryBlock: nil, blockLength: length, blockAllocator: nil,
            customBlockSource: nil, offsetToData: 0, dataLength: length,
            flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block
        )
        var pointer: UnsafeMutablePointer<CChar>?
        guard let block,
              CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: nil, dataPointerOut: &pointer) == noErr,
              let pointer else { return nil }
        memset(pointer, 0, length)
        if let fill {
            pointer.withMemoryRebound(to: Int16.self, capacity: length / 2) { fill($0) }
        }
        var sample: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: frames,
            presentationTimeStamp: time, packetDescriptions: nil, sampleBufferOut: &sample
        )
        return sample
    }
}
