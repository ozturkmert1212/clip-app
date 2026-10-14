import AppKit
import AVFoundation
import CryptoKit
import UniformTypeIdentifiers

/// Clip thumbnails, generated off the main thread and kept as JPEG files in
/// the Caches folder. A file that changes gets a new fingerprint and with it
/// a new thumbnail.
final class ThumbnailCache {
    static let shared = ThumbnailCache()

    private static let maximumSize = CGSize(width: 640, height: 360)

    private let memory = NSCache<NSString, NSImage>()
    private let directory: URL

    private init() {
        directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "ClipApp", isDirectory: true)
            .appendingPathComponent("Thumbnails", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func image(for clip: ClipItem) async -> NSImage? {
        let key = SHA256.hash(data: Data(clip.fingerprint.utf8)).map { String(format: "%02x", $0) }.joined()
        if let cached = memory.object(forKey: key as NSString) { return cached }

        let file = directory.appendingPathComponent(key).appendingPathExtension("jpg")
        let frame = await Task.detached(priority: .utility) { () -> CGImage? in
            if let source = CGImageSourceCreateWithURL(file as CFURL, nil),
               let stored = CGImageSourceCreateImageAtIndex(source, 0, nil) {
                return stored
            }
            guard let generated = await Self.generate(for: clip.url) else { return nil }
            Self.write(generated, to: file)
            return generated
        }.value
        guard let frame else { return nil }
        let image = NSImage(cgImage: frame, size: NSSize(width: frame.width, height: frame.height))
        memory.setObject(image, forKey: key as NSString)
        return image
    }

    private static func generate(for url: URL) async -> CGImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = maximumSize
        // A little way in: the very first frame is often a menu or a fade.
        let duration = (try? await asset.load(.duration))?.seconds ?? 0
        let time = CMTime(seconds: min(1, max(0, duration / 2)), preferredTimescale: 600)
        return try? await generator.image(at: time).image
    }

    private static func write(_ image: CGImage, to file: URL) {
        guard let destination = CGImageDestinationCreateWithURL(
            file as CFURL, UTType.jpeg.identifier as CFString, 1, nil
        ) else { return }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        CGImageDestinationFinalize(destination)
    }
}
