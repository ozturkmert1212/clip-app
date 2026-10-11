import AVFoundation
import CoreAudio
import OSLog

/// Captures the system default input device. Separate from `SCStream`, whose
/// own microphone capture only exists on macOS 15 and later.
final class MicrophoneCapture: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    private let logger = Logger(subsystem: "com.mertozturk.ClipApp", category: "microphone")
    /// Serializes session changes and delivers the samples.
    private let queue = DispatchQueue(label: "com.mertozturk.ClipApp.microphone", qos: .userInteractive)
    private let onSample: (CMSampleBuffer, CMTime) -> Void
    private var session: AVCaptureSession?
    private var enabled = false

    /// `onSample` gets each buffer with its timestamp on the host clock.
    init(onSample: @escaping (CMSampleBuffer, CMTime) -> Void) {
        self.onSample = onSample
        super.init()

        // Follows the user switching input device, and a device showing up
        // when there was none.
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue) { [weak self] _, _ in
            self?.restart()
        }
        NotificationCenter.default.addObserver(
            forName: AVCaptureSession.runtimeErrorNotification, object: nil, queue: nil
        ) { [weak self] notification in
            let session = notification.object as? AVCaptureSession
            self?.queue.asyncAfter(deadline: .now() + 1) {
                guard let self, session === self.session else { return }
                self.restart()
            }
        }
    }

    /// The caller only enables this once the microphone permission is granted;
    /// opening the device without it would pop the system prompt.
    func setEnabled(_ enabled: Bool) {
        queue.async {
            guard enabled != self.enabled else { return }
            self.enabled = enabled
            self.restart()
        }
    }

    private func restart() {
        if let session {
            session.stopRunning()
            self.session = nil
        }
        guard enabled else { return }
        guard let device = AVCaptureDevice.default(for: .audio),
              let input = try? AVCaptureDeviceInput(device: device) else {
            logger.error("No usable microphone")
            return
        }
        let session = AVCaptureSession()
        let output = AVCaptureAudioDataOutput()
        // Same rate as the system audio so the two can be mixed into one track.
        // The channel count stays the device's.
        output.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48_000,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddInput(input), session.canAddOutput(output) else {
            logger.error("Cannot configure microphone session")
            return
        }
        session.addInput(input)
        session.addOutput(output)
        session.startRunning()
        self.session = session
        logger.info("Microphone started: \(device.localizedName, privacy: .public)")
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        // The session stamps buffers on its own clock, which for an audio-only
        // session is the device clock. Everything else here is on the host clock.
        let hostClock = CMClockGetHostTimeClock()
        var time = sampleBuffer.presentationTimeStamp
        if let clock = session?.synchronizationClock, clock != hostClock {
            time = CMSyncConvertTime(time, from: clock, to: hostClock)
        }
        onSample(sampleBuffer, time)
    }
}
