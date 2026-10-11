import CoreMedia

/// Order is the order of the audio tracks in a clip.
enum AudioTrack: CaseIterable {
    case system, microphone
}

/// Keeps the most recent encoded samples in memory. Safe to append from the
/// encoder callback while another thread takes a snapshot.
final class RingBuffer {
    struct Snapshot {
        /// Starts on a keyframe, which may lie before `startTime`.
        let video: [CMSampleBuffer]
        /// PCM that overlaps the clip; a track without audio is absent.
        let audio: [AudioTrack: [CMSampleBuffer]]
        let startTime: CMTime
        let endTime: CMTime
    }

    private struct Entry {
        let sample: CMSampleBuffer
        let time: CMTime
        let isKeyframe: Bool
        var size = 0
    }

    struct VideoStatus {
        let bytes: Int
        /// Seconds between the oldest and the newest buffered frame.
        let span: TimeInterval
        /// The byte limit, not the duration, currently decides how far back the buffer reaches.
        let isByteLimited: Bool
    }

    private let lock = NSLock()
    private var duration: CMTime
    private var video: [Entry] = []
    private var videoBytes = 0
    private var byteLimit: Int
    private var isByteLimited = false
    private var audio: [AudioTrack: [Entry]] = [:]

    /// `byteLimit` caps the encoded video held in memory. The encoder treats
    /// its bitrate as a target only, and content that does not compress
    /// (noise, heavy grain) overshoots it many times over.
    init(duration: TimeInterval, byteLimit: Int) {
        self.duration = CMTime(seconds: duration, preferredTimescale: 600)
        self.byteLimit = byteLimit
    }

    /// A lower limit takes effect on the next frame.
    func setByteLimit(_ byteLimit: Int) {
        lock.lock()
        defer { lock.unlock() }
        self.byteLimit = byteLimit
    }

    func videoStatus() -> VideoStatus {
        lock.lock()
        defer { lock.unlock() }
        let span = video.last.map { ($0.time - video[0].time).seconds } ?? 0
        return VideoStatus(bytes: videoBytes, span: span, isByteLimited: isByteLimited)
    }

    /// A shorter duration takes effect on the next keyframe; a longer one fills
    /// up as new frames arrive.
    func setDuration(_ duration: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        self.duration = CMTime(seconds: duration, preferredTimescale: 600)
    }

    func append(_ sample: CMSampleBuffer) {
        let entry = Entry(
            sample: sample,
            time: sample.presentationTimeStamp,
            isKeyframe: Self.isKeyframe(sample),
            size: sample.totalSampleSize
        )

        lock.lock()
        defer { lock.unlock() }

        if let last = video.last {
            // One mp4 track cannot switch parameter sets, so footage from before
            // a resolution change is dropped.
            if let old = last.sample.formatDescription, let new = sample.formatDescription,
               !CMFormatDescriptionEqual(old, otherFormatDescription: new) {
                video.removeAll()
                videoBytes = 0
                isByteLimited = false
            }
        }
        // Nothing is decodable until the first keyframe.
        guard entry.isKeyframe || !video.isEmpty else { return }
        video.append(entry)
        videoBytes += entry.size

        // Prune whole GOPs only, so the buffer always starts on a keyframe and
        // still covers the full duration.
        if entry.isKeyframe {
            let cutoff = entry.time - duration
            if let keep = video.lastIndex(where: { $0.isKeyframe && $0.time <= cutoff }), keep > 0 {
                removeFirstVideo(keep)
                // Reaching the full duration again means the limit no longer bites.
                isByteLimited = false
            }
        }

        // Over the byte limit the oldest GOPs go, whatever their age. The GOP
        // being filled always stays, so the buffer remains decodable.
        while videoBytes > byteLimit, let next = video.dropFirst().firstIndex(where: \.isKeyframe) {
            removeFirstVideo(next)
            isByteLimited = true
        }
    }

    func append(_ sample: CMSampleBuffer, to track: AudioTrack) {
        let entry = Entry(sample: sample, time: sample.presentationTimeStamp, isKeyframe: true)

        lock.lock()
        defer { lock.unlock() }

        // A different input device can change sample rate or channel count,
        // and one track holds one format.
        if let old = audio[track]?.last?.sample.formatDescription, let new = sample.formatDescription,
           !CMFormatDescriptionEqual(old, otherFormatDescription: new) {
            audio[track] = []
        }
        audio[track, default: []].append(entry)

        // Pruned about once a second rather than on every buffer. The extra
        // second also covers a snapshot taken slightly after the newest buffer.
        let second = CMTime(value: 1, timescale: 1)
        let cutoff = entry.time - duration - second
        if let first = audio[track]?.first, first.time < cutoff - second {
            audio[track]?.removeAll { $0.time < cutoff }
        }
    }

    func removeAudio(_ track: AudioTrack) {
        lock.lock()
        defer { lock.unlock() }
        audio[track] = nil
    }

    /// The last `duration` seconds up to `now`. `now` rather than the newest
    /// sample marks the end because a static screen produces no frames.
    func snapshot(endingAt now: CMTime) -> Snapshot? {
        lock.lock()
        defer { lock.unlock() }

        guard let first = video.first else { return nil }
        let windowStart = now - duration
        let startIndex = video.lastIndex { $0.isKeyframe && $0.time <= windowStart } ?? 0
        let startTime = max(windowStart, first.time)
        let audio = self.audio.compactMapValues { entries -> [CMSampleBuffer]? in
            let samples = entries
                .filter { $0.time + $0.sample.duration > startTime && $0.time < now }
                .map(\.sample)
            return samples.isEmpty ? nil : samples
        }
        return Snapshot(
            video: video[startIndex...].map(\.sample),
            audio: audio,
            startTime: startTime,
            endTime: now
        )
    }

    private func removeFirstVideo(_ count: Int) {
        videoBytes -= video[..<count].reduce(0) { $0 + $1.size }
        video.removeFirst(count)
    }

    private static func isKeyframe(_ sample: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false)
                as? [[CFString: Any]],
              let notSync = attachments.first?[kCMSampleAttachmentKey_NotSync] as? Bool else { return true }
        return !notSync
    }
}
