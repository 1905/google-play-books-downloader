import AppKit
import ImageIO
import SwiftUI

/// Downscaled page images, decoded off the main thread and cached in memory.
@MainActor
enum Thumbnails {
    private static let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 600
        return c
    }()

    private static func key(_ url: URL, _ maxPixel: Int) -> NSString {
        "\(maxPixel)|\(url.path)" as NSString
    }

    /// Cached thumbnail, nil when it has not been decoded yet.
    static func cached(_ url: URL, maxPixel: Int) -> NSImage? {
        cache.object(forKey: key(url, maxPixel))
    }

    /// Thumbnail no larger than `maxPixel` on its long side. nil if the file is unreadable.
    static func image(for url: URL, maxPixel: Int) async -> NSImage? {
        if let hit = cached(url, maxPixel: maxPixel) { return hit }
        guard let cg = await Task.detached(priority: .userInitiated, operation: { decode(url, maxPixel: maxPixel) }).value
        else { return nil }
        let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        cache.setObject(image, forKey: key(url, maxPixel))
        return image
    }

    /// Full-size image for the page viewer, decoded off the main thread (not cached).
    static func fullImage(for url: URL) async -> NSImage? {
        let decoded = await Task.detached(priority: .userInitiated) { () -> CGImage? in
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            return CGImageSourceCreateImageAtIndex(src, 0, nil)
        }.value
        guard let cg = decoded else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    nonisolated private static func decode(_ url: URL, maxPixel: Int) -> CGImage? {
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }
}

/// Page thumbnail that loads itself; a soft placeholder until it's ready.
struct ThumbnailImage: View {
    let url: URL
    var maxPixel = 320
    @State private var image: NSImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            if failed {
                RoundedRectangle(cornerRadius: 4)
                    .fill(.quaternary)
                    .overlay(Image(systemName: "photo.badge.exclamationmark").foregroundStyle(.secondary))
            } else if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .transition(.opacity)
            } else {
                RoundedRectangle(cornerRadius: 4)
                    .fill(.quaternary)
                    .overlay(ProgressView().controlSize(.small))
            }
        }
        .animation(.easeOut(duration: 0.15), value: image != nil)
        .task(id: url) {
            failed = false
            image = Thumbnails.cached(url, maxPixel: maxPixel)
            if image == nil {
                image = await Thumbnails.image(for: url, maxPixel: maxPixel)
                failed = image == nil
            }
        }
    }
}
