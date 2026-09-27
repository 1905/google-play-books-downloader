import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Where captured pages live: `~/Library/Caches/google-play-books-downloader/<run-name>/`.
public enum CachePaths {
    /// Tests only: replaces the cache root.
    static var rootOverride: URL?

    public static func root() -> URL {
        if let rootOverride { return rootOverride }
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches")
        return caches.appendingPathComponent("google-play-books-downloader", isDirectory: true)
    }

    public static func runDirectory(name: String) -> URL {
        root().appendingPathComponent(name, isDirectory: true)
    }

    /// Creates and returns a fresh run directory: `runDirectory(name:)`, else the first of
    /// `<name>-2`, `<name>-3`, … that doesn't exist yet. Each candidate is claimed with a
    /// non-intermediate `createDirectory`, so "already exists" (even an empty dir, or a dir a
    /// concurrent capture just claimed) means taken. Two runs with the same name never share a dir.
    /// Throws `PageSinkError.notWritable` if the root or a candidate can't be created.
    public static func uniqueRunDirectory(name: String) throws -> URL {
        let fm = FileManager.default
        do { try fm.createDirectory(at: root(), withIntermediateDirectories: true) } catch {
            throw PageSinkError.notWritable(root())
        }
        var n = 1
        while true {
            let candidate = runDirectory(name: n == 1 ? name : "\(name)-\(n)")
            do {
                try fm.createDirectory(at: candidate, withIntermediateDirectories: false)
                return candidate
            } catch CocoaError.fileWriteFileExists {
                n += 1
            } catch {
                throw PageSinkError.notWritable(candidate)
            }
        }
    }

    /// "yyyy-MM-dd_HHmmss" in the current time zone.
    public static func defaultRunName(date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM-dd_HHmmss"
        return f.string(from: date)
    }
}

/// Receives page images in order. Numbering is the sink's job.
public protocol PageSink: AnyObject {
    func save(_ image: CGImage) throws -> URL
    /// Replaces the last `count` saved images with one image; returns its URL. Numbering goes
    /// on after it. The default throws `PageSinkError.replaceUnsupported`.
    func replaceLast(_ count: Int, with image: CGImage) throws -> URL
    /// Removes the last `count` saved images. Numbering goes on after the remaining ones.
    /// The default throws `PageSinkError.replaceUnsupported`.
    func dropLast(_ count: Int) throws
}

public extension PageSink {
    func replaceLast(_ count: Int, with image: CGImage) throws -> URL {
        throw PageSinkError.replaceUnsupported
    }

    func dropLast(_ count: Int) throws {
        throw PageSinkError.replaceUnsupported
    }
}

public enum PageSinkError: Error {
    case notWritable(URL), encodeFailed(URL), replaceUnsupported
}

/// Writes pages as `0001.jpg`, `0002.jpg`, … (sRGB, no alpha) into one directory.
/// PDFExporter embeds these JPEG bytes as-is, so `jpegQuality` is the final PDF quality too.
public final class DiskPageSink: PageSink {
    public let directory: URL
    public let jpegQuality: Double
    private var count = 0

    /// Creates `directory` (with parents) unless it already exists, e.g. from
    /// `CachePaths.uniqueRunDirectory`. Throws if it can't be created or isn't writable.
    /// `jpegQuality` is clamped to 0…1.
    public init(directory: URL, jpegQuality: Double = 0.85) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard FileManager.default.isWritableFile(atPath: directory.path) else {
            throw PageSinkError.notWritable(directory)
        }
        self.directory = directory
        self.jpegQuality = min(max(jpegQuality, 0), 1)
    }

    public func save(_ image: CGImage) throws -> URL {
        let url = pageURL(count + 1)
        try write(image, to: url)
        count += 1
        return url
    }

    /// Overwrites the first of the last `n` files with `image`. The others are moved into
    /// `.replaced/` in the run directory (kept, not deleted), so numbering stays gapless.
    public func replaceLast(_ n: Int, with image: CGImage) throws -> URL {
        guard n >= 1, n <= count else { throw PageSinkError.replaceUnsupported }
        let first = count - n + 1
        let url = pageURL(first)
        try write(image, to: url)
        try setAside(from: first + 1)
        return url
    }

    /// Moves the last `n` files into `.replaced/` (kept, not deleted).
    public func dropLast(_ n: Int) throws {
        guard n >= 1, n <= count else { throw PageSinkError.replaceUnsupported }
        try setAside(from: count - n + 1)
    }

    /// Moves files `first...count` into `.replaced/`; numbering continues at `first`.
    private func setAside(from first: Int) throws {
        guard first <= count else {
            count = first - 1
            return
        }
        let fm = FileManager.default
        let aside = directory.appendingPathComponent(".replaced", isDirectory: true)
        try fm.createDirectory(at: aside, withIntermediateDirectories: true)
        for i in first...count {
            let from = pageURL(i)
            var to = aside.appendingPathComponent(from.lastPathComponent)
            if fm.fileExists(atPath: to.path) {  // an earlier replace set aside the same number
                to = aside.appendingPathComponent("\(from.deletingPathExtension().lastPathComponent)-\(UUID().uuidString).\(from.pathExtension)")
            }
            try fm.moveItem(at: from, to: to)
        }
        count = first - 1
    }

    private func pageURL(_ n: Int) -> URL {
        directory.appendingPathComponent(String(format: "%04d.jpg", n))
    }

    private func write(_ image: CGImage, to url: URL) throws {
        guard let data = JPEGEncoding.data(image, quality: jpegQuality) else { throw PageSinkError.encodeFailed(url) }
        do { try data.write(to: url) } catch { throw PageSinkError.encodeFailed(url) }
    }
}

/// JPEG encoding shared by DiskPageSink and PDFExporter's non-JPEG fallback.
enum JPEGEncoding {
    /// `image` redrawn into an 8-bit sRGB bitmap without alpha (alpha composited over white).
    static func opaqueSRGB(_ image: CGImage) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(rect)
        ctx.draw(image, in: rect)
        return ctx.makeImage()
    }

    /// In-memory JPEG of `image` at `quality`. nil if encoding fails.
    static func data(_ image: CGImage, quality: Double) -> Data? {
        guard let rgb = opaqueSRGB(image) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        let opts = [kCGImageDestinationLossyCompressionQuality: min(max(quality, 0), 1)] as CFDictionary
        CGImageDestinationAddImage(dest, rgb, opts)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }
}
