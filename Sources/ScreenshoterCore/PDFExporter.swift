import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum PDFExportError: Error {
    case noImages, unreadableImage(URL), writeFailed(URL)
}

/// PDF size preset. Only the image resolution and JPEG quality change: the page size in points
/// is always taken from the original pixel size, so every preset prints at the same size.
public enum PDFSize: String, CaseIterable {
    case full, balanced, small

    /// Pages taller than this are downscaled (aspect kept). nil = never.
    public var maxPageHeight: Int? {
        switch self {
        case .full: return nil
        case .balanced: return 1600
        case .small: return 1200
        }
    }

    /// JPEG quality of re-encoded pages. `.full` embeds JPEG files as-is; the value is only used
    /// for non-JPEG inputs (PNG pages from older runs).
    public var jpegQuality: Double {
        switch self {
        case .full: return 0.85
        case .balanced: return 0.75
        case .small: return 0.65
        }
    }

    /// Rough PDF size relative to the summed page files, for "≈" estimates before export.
    public var estimateFactor: Double {
        switch self {
        case .full: return 1.0
        case .balanced: return 0.55
        case .small: return 0.3
        }
    }
}

/// Images → PDF, one page per image. Page size = original pixel size at `dpi` (144 → 2× captures
/// print at screen size).
/// - `.full`: JPEG files are embedded byte-for-byte (CoreGraphics passes DCT data through, no
///   re-encode). Other formats are decoded and JPEG-encoded at `jpegQuality`.
/// - other presets: every page is decoded, downscaled if taller than `size.maxPageHeight`, and
///   re-encoded at `size.jpegQuality`. Pages are encoded concurrently in chunks, so only one
///   chunk of encoded pages is in memory at a time; pages are still written in order.
public enum PDFExporter {
    /// Writes to a hidden `.<name>.partial-<uuid>.pdf` next to `url`, closes it, checks that it
    /// parses with one page per image, then moves it over `url`. Any failure (full disk, a page
    /// that won't decode) leaves `url` untouched and moves the partial file to `/tmp/trash/`.
    public static func export(imageURLs: [URL], to url: URL, size: PDFSize = .full,
                              jpegQuality: Double = 0.85, dpi: Double = 144) throws {
        guard !imageURLs.isEmpty else { throw PDFExportError.noImages }
        // Open every input first: a bad input fails before any file is created.
        let sources = try imageURLs.map(Source.init)
        let fullImages = size == .full ? try sources.map { try $0.jpegBackedImage(fallbackQuality: jpegQuality) } : []
        let base = url.deletingPathExtension().lastPathComponent
        let temp = url.deletingLastPathComponent()
            .appendingPathComponent(".\(base).partial-\(UUID().uuidString).pdf")
        do {
            try writePDF(to: temp, finalURL: url, sources: sources, fullImages: fullImages, size: size, dpi: dpi)
            guard isValidPDF(temp, pageCount: imageURLs.count) else { throw PDFExportError.writeFailed(url) }
            let fm = FileManager.default
            do {
                if fm.fileExists(atPath: url.path) {
                    _ = try fm.replaceItemAt(url, withItemAt: temp)
                } else {
                    try fm.moveItem(at: temp, to: url)
                }
            } catch {
                throw PDFExportError.writeFailed(url)
            }
        } catch {
            discard(temp)
            throw error
        }
    }

    /// True if `url` parses as a PDF with exactly `pageCount` pages.
    static func isValidPDF(_ url: URL, pageCount: Int) -> Bool {
        CGPDFDocument(url as CFURL)?.numberOfPages == pageCount
    }

    /// Moves a failed partial file to `/tmp/trash/` (never deletes). No-op if it doesn't exist.
    private static func discard(_ temp: URL) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: temp.path) else { return }
        let trash = URL(fileURLWithPath: "/tmp/trash", isDirectory: true)
        try? fm.createDirectory(at: trash, withIntermediateDirectories: true)
        try? fm.moveItem(at: temp, to: trash.appendingPathComponent(temp.lastPathComponent))
    }

    /// Draws every page into a new PDF at `temp` and closes it before returning, also on error,
    /// so the file is complete on disk when the caller validates it.
    private static func writePDF(to temp: URL, finalURL: URL, sources: [Source], fullImages: [CGImage],
                                 size: PDFSize, dpi: Double) throws {
        guard let ctx = CGContext(temp as CFURL, mediaBox: nil, nil) else { throw PDFExportError.writeFailed(finalURL) }
        func draw(_ image: CGImage, _ source: Source) {
            var box = CGRect(x: 0, y: 0, width: Double(source.width) * 72 / dpi, height: Double(source.height) * 72 / dpi)
            ctx.beginPage(mediaBox: &box)
            ctx.draw(image, in: box)
            ctx.endPage()
        }
        do {
            if size == .full {
                for (s, image) in zip(sources, fullImages) { draw(image, s) }
            } else {
                let chunk = max(ProcessInfo.processInfo.activeProcessorCount, 1) * 2
                for start in stride(from: 0, to: sources.count, by: chunk) {
                    let part = Array(sources[start..<min(start + chunk, sources.count)])
                    var encoded = [Data?](repeating: nil, count: part.count)
                    encoded.withUnsafeMutableBufferPointer { out in
                        DispatchQueue.concurrentPerform(iterations: part.count) { i in
                            out[i] = part[i].reencoded(maxHeight: size.maxPageHeight, quality: size.jpegQuality)
                        }
                    }
                    for (s, data) in zip(part, encoded) {
                        guard let image = data.flatMap({ CGDataProvider(data: $0 as CFData) }).flatMap(jpegImage) else { throw PDFExportError.unreadableImage(s.url) }
                        draw(image, s)
                    }
                }
            }
        } catch {
            ctx.closePDF()
            throw error
        }
        ctx.closePDF()
    }

    /// One opened input with its original pixel size.
    private struct Source {
        let url: URL
        let src: CGImageSource
        let isJPEG: Bool
        let width: Int
        let height: Int

        init(_ url: URL) throws {
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let type = CGImageSourceGetType(src),
                  let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
                  let w = props[kCGImagePropertyPixelWidth] as? Int, w > 0,
                  let h = props[kCGImagePropertyPixelHeight] as? Int, h > 0
            else { throw PDFExportError.unreadableImage(url) }
            self.url = url
            self.src = src
            isJPEG = UTType(type as String)?.conforms(to: .jpeg) == true
            width = w
            height = h
        }

        /// A CGImage backed by JPEG data: the file itself when it is a JPEG, else an in-memory re-encode.
        func jpegBackedImage(fallbackQuality: Double) throws -> CGImage {
            let provider: CGDataProvider? = isJPEG
                ? CGDataProvider(url: url as CFURL)
                : CGImageSourceCreateImageAtIndex(src, 0, nil)
                    .flatMap { JPEGEncoding.data($0, quality: fallbackQuality) }
                    .flatMap { CGDataProvider(data: $0 as CFData) }
            guard let image = provider.flatMap(jpegImage) else { throw PDFExportError.unreadableImage(url) }
            return image
        }

        /// Decoded, downscaled to `maxHeight` if taller (high-quality ImageIO thumbnail, aspect
        /// kept), JPEG-encoded at `quality`. nil if decoding or encoding fails.
        func reencoded(maxHeight: Int?, quality: Double) -> Data? {
            let image: CGImage?
            if let maxHeight, height > maxHeight {
                // Thumbnail max size limits the longer side; scale it by the height ratio.
                let maxSide = Int((Double(max(width, height)) * Double(maxHeight) / Double(height)).rounded())
                let opts = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                            kCGImageSourceCreateThumbnailWithTransform: false,
                            kCGImageSourceShouldCacheImmediately: true,
                            kCGImageSourceThumbnailMaxPixelSize: maxSide] as CFDictionary
                image = CGImageSourceCreateThumbnailAtIndex(src, 0, opts)
            } else {
                image = CGImageSourceCreateImageAtIndex(src, 0, nil)
            }
            return image.flatMap { JPEGEncoding.data($0, quality: quality) }
        }
    }

    /// A CGImage that keeps the provider's JPEG bytes as its source, so the PDF embeds them without re-encoding.
    private static func jpegImage(_ provider: CGDataProvider) -> CGImage? {
        CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
