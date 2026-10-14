import CoreMedia
import Foundation

/// Sample buffers that look like the pipeline's output to the ring buffer
/// (timing, size, keyframe flag, format) without holding real media.
enum FakeSamples {
    static func videoFormat(width: Int32 = 1280, height: Int32 = 720) -> CMFormatDescription {
        var format: CMFormatDescription?
        CMVideoFormatDescriptionCreate(
            allocator: nil, codecType: kCMVideoCodecType_H264, width: width, height: height,
            extensions: nil, formatDescriptionOut: &format
        )
        return format!
    }

    static let audioFormat: CMAudioFormatDescription = {
        var description = AudioStreamBasicDescription(
            mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 2,
            mBitsPerChannel: 16, mReserved: 0
        )
        var format: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(
            allocator: nil, asbd: &description, layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format
        )
        return format!
    }()

    static func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 600)
    }

    static func video(at seconds: Double, keyframe: Bool, bytes: Int = 1000, format: CMFormatDescription) -> CMSampleBuffer {
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(
            allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil, customBlockSource: nil,
            offsetToData: 0, dataLength: bytes, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block
        )
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: time(seconds), decodeTimeStamp: .invalid)
        var size = bytes
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReady(
            allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample
        )
        if !keyframe, let attachments = CMSampleBufferGetSampleAttachmentsArray(sample!, createIfNecessary: true) {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(
                dictionary,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
            )
        }
        return sample!
    }

    /// Silence of the given length in the pipeline's audio format.
    static func audio(at seconds: Double, frames: Int = 4800) -> CMSampleBuffer {
        AudioPipeline.makeBuffer(
            format: audioFormat, frames: frames,
            time: CMTime(value: CMTimeValue((seconds * 48_000).rounded()), timescale: 48_000)
        )!
    }

    /// Feeds `buffer` `seconds` of video at 30 fps with a keyframe every
    /// `gop` seconds, starting at `start`.
    static func fill(
        _ buffer: RingBuffer, from start: Double = 0, seconds: Double, gop: Int = 2,
        bytes: Int = 1000, format: CMFormatDescription
    ) {
        for index in 0..<Int(seconds * 30) {
            buffer.append(video(at: start + Double(index) / 30, keyframe: index % (gop * 30) == 0, bytes: bytes, format: format))
        }
    }
}
