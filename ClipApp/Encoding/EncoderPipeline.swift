import CoreMedia
import OSLog
import VideoToolbox

/// Hardware H.264 encoder. Raw frames go in on the capture queue and are
/// released as soon as VideoToolbox is done with them; only the encoded
/// samples are handed on.
final class EncoderPipeline {
    private var fps: Int
    private var bitrate: Int
    private let onEncoded: (CMSampleBuffer) -> Void
    private let logger = Logger(subsystem: "com.mertozturk.ClipApp", category: "encoder")

    private let lock = NSLock()
    private var session: VTCompressionSession?
    private var width: Int32 = 0
    private var height: Int32 = 0
    private var lastStatus = noErr

    /// Keyframes bound how far back a clip has to start and how coarsely the
    /// ring buffer can prune.
    private static let keyframeInterval = 2

    init(fps: Int, bitrate: Int, onEncoded: @escaping (CMSampleBuffer) -> Void) {
        self.fps = fps
        self.bitrate = bitrate
        self.onEncoded = onEncoded
    }

    deinit {
        invalidateSession()
    }

    /// The session is rebuilt on the next frame, which also starts a new GOP.
    func configure(fps: Int, bitrate: Int) {
        lock.lock()
        defer { lock.unlock() }
        guard fps != self.fps || bitrate != self.bitrate else { return }
        self.fps = fps
        self.bitrate = bitrate
        invalidateSession()
    }

    func encode(_ sampleBuffer: CMSampleBuffer) {
        guard let imageBuffer = sampleBuffer.imageBuffer else { return }
        let frameWidth = Int32(CVPixelBufferGetWidth(imageBuffer))
        let frameHeight = Int32(CVPixelBufferGetHeight(imageBuffer))

        lock.lock()
        defer { lock.unlock() }

        // The stream changes size when the source or display changes.
        if session == nil || frameWidth != width || frameHeight != height {
            invalidateSession()
            makeSession(width: frameWidth, height: frameHeight)
        }
        guard let session else { return }

        let status = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: imageBuffer,
            presentationTimeStamp: sampleBuffer.presentationTimeStamp,
            duration: .invalid,
            frameProperties: nil,
            infoFlagsOut: nil
        ) { [onEncoded] status, flags, encoded in
            guard status == noErr, let encoded, !flags.contains(.frameDropped) else { return }
            onEncoded(encoded)
        }

        if status != lastStatus {
            lastStatus = status
            if status != noErr { logger.error("Encode failed: \(status)") }
        }
        // The session dies across GPU resets and some sleep/wake cycles; the
        // next frame builds a fresh one.
        if status == kVTInvalidSessionErr {
            invalidateSession()
        }
    }

    private func makeSession(width: Int32, height: Int32) {
        var created: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: nil,
            width: width,
            height: height,
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true] as CFDictionary,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &created
        )
        guard status == noErr, let created else {
            logger.error("Could not create compression session: \(status)")
            return
        }

        let properties: [CFString: Any] = [
            kVTCompressionPropertyKey_RealTime: true,
            kVTCompressionPropertyKey_ProfileLevel: kVTProfileLevel_H264_High_AutoLevel,
            // No B-frames: decode order equals presentation order, which keeps
            // the ring buffer and the passthrough mux simple.
            kVTCompressionPropertyKey_AllowFrameReordering: false,
            kVTCompressionPropertyKey_MaxKeyFrameInterval: fps * Self.keyframeInterval,
            kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration: Self.keyframeInterval,
            kVTCompressionPropertyKey_ExpectedFrameRate: fps,
            kVTCompressionPropertyKey_AverageBitRate: bitrate,
            kVTCompressionPropertyKey_ColorPrimaries: kCVImageBufferColorPrimaries_ITU_R_709_2,
            kVTCompressionPropertyKey_TransferFunction: kCVImageBufferTransferFunction_ITU_R_709_2,
            kVTCompressionPropertyKey_YCbCrMatrix: kCVImageBufferYCbCrMatrix_ITU_R_709_2,
        ]
        let propertyStatus = VTSessionSetProperties(created, propertyDictionary: properties as CFDictionary)
        if propertyStatus != noErr {
            logger.error("Could not apply encoder properties: \(propertyStatus)")
        }
        VTCompressionSessionPrepareToEncodeFrames(created)

        session = created
        self.width = width
        self.height = height
        logger.info("Encoder session \(width)x\(height) @ \(self.fps) fps, \(self.bitrate) bps")
    }

    private func invalidateSession() {
        guard let session else { return }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        VTCompressionSessionInvalidate(session)
        self.session = nil
    }
}
