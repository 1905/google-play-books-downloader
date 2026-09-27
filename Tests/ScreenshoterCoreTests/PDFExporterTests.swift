import ImageIO
import PDFKit
import UniformTypeIdentifiers
import XCTest
@testable import ScreenshoterCore

final class PDFExporterTests: XCTestCase {
    var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("PDFExporterTests-\(UUID().uuidString)", isDirectory: true)
    }

    func writeJPEGs(_ n: Int) throws -> [URL] {
        let sink = try DiskPageSink(directory: tmp.appendingPathComponent("imgs"))
        return try (0..<n).map { i in
            try sink.save(TestImages.rgbCGImage(288, 432, fill: (UInt8(200 - i * 50), 20, 40)))
        }
    }

    /// PNG pages, as older runs wrote them.
    func writePNGs(_ n: Int) throws -> [URL] {
        let dir = tmp.appendingPathComponent("pngs", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try (0..<n).map { i in
            let url = dir.appendingPathComponent(String(format: "%04d.png", i + 1))
            let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(dest, TestImages.rgbCGImage(288, 432, fill: (UInt8(200 - i * 50), 20, 40)), nil)
            XCTAssertTrue(CGImageDestinationFinalize(dest))
            return url
        }
    }

    func assertPages(_ out: URL, count: Int, width: Double = 144, height: Double = 216,
                     file: StaticString = #filePath, line: UInt = #line) throws {
        let doc = try XCTUnwrap(PDFDocument(url: out), file: file, line: line)
        XCTAssertEqual(doc.pageCount, count, file: file, line: line)
        for i in 0..<doc.pageCount {
            let box = try XCTUnwrap(doc.page(at: i), file: file, line: line).bounds(for: .mediaBox)
            XCTAssertEqual(box.width, width, accuracy: 0.01, file: file, line: line)
            XCTAssertEqual(box.height, height, accuracy: 0.01, file: file, line: line)
        }
    }

    /// Renders page 0 at 1 px per point; corners and centre must be the red-ish image colour,
    /// not the white page background.
    func assertFillsPage(_ out: URL, file: StaticString = #filePath, line: UInt = #line) throws {
        let page = try XCTUnwrap(PDFDocument(url: out)?.page(at: 0), file: file, line: line)
        let w = 144, h = 216
        let ctx = try XCTUnwrap(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        page.draw(with: .mediaBox, to: ctx)
        let data = try XCTUnwrap(ctx.data).assumingMemoryBound(to: UInt8.self)
        for (x, y) in [(3, 3), (w - 4, 3), (3, h - 4), (w - 4, h - 4), (w / 2, h / 2)] {
            let o = (y * w + x) * 4
            XCTAssertGreaterThan(Int(data[o]), 150, "red at \(x),\(y)", file: file, line: line)
            XCTAssertLessThan(Int(data[o + 1]), 80, "green at \(x),\(y)", file: file, line: line)
        }
    }

    func fileSize(_ url: URL) throws -> Int {
        try XCTUnwrap(url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
    }

    func testThreePagesAt144Dpi() throws {
        let out = tmp.appendingPathComponent("out.pdf")
        try PDFExporter.export(imageURLs: try writeJPEGs(3), to: out)
        try assertPages(out, count: 3)
    }

    func testImageFillsPage() throws {
        let out = tmp.appendingPathComponent("fill.pdf")
        try PDFExporter.export(imageURLs: try writeJPEGs(1), to: out)
        try assertFillsPage(out)
    }

    /// JPEG pages go in byte-for-byte: each file's bytes appear verbatim in the PDF, and the PDF
    /// is barely bigger than the JPEGs together. Pages are half-size captures (700×1048) so the
    /// fixed PDF overhead (~2.6 KB shared ICC profile + <1 KB per page) doesn't dominate.
    func testJPEGBytesArePassedThrough() throws {
        let sink = try DiskPageSink(directory: tmp.appendingPathComponent("comic"))
        let urls = try (0..<3).map { i in
            try sink.save(TestImages.cgImage(from: TestImages.noisePage(700, 1048, seed: UInt64(i + 1))))
        }
        let out = tmp.appendingPathComponent("pass.pdf")
        try PDFExporter.export(imageURLs: urls, to: out)
        try assertPages(out, count: 3, width: 350, height: 524)
        let pdf = try Data(contentsOf: out)
        for url in urls {
            XCTAssertNotNil(pdf.range(of: try Data(contentsOf: url)), "\(url.lastPathComponent) not embedded as-is")
        }
        let jpegTotal = try urls.map(fileSize).reduce(0, +)
        XCTAssertLessThanOrEqual(Double(pdf.count), 1.1 * Double(jpegTotal), "pdf \(pdf.count) B, jpegs \(jpegTotal) B")
    }

    func testPNGInputsStillWork() throws {
        let out = tmp.appendingPathComponent("png.pdf")
        try PDFExporter.export(imageURLs: try writePNGs(3), to: out)
        try assertPages(out, count: 3)
        try assertFillsPage(out)
    }

    func testMixedPNGAndJPEGInputs() throws {
        let out = tmp.appendingPathComponent("mixed.pdf")
        try PDFExporter.export(imageURLs: try writePNGs(1) + writeJPEGs(2), to: out)
        try assertPages(out, count: 3)
    }

    func testEmptyListThrows() {
        XCTAssertThrowsError(try PDFExporter.export(imageURLs: [], to: tmp.appendingPathComponent("x.pdf"))) {
            guard case PDFExportError.noImages = $0 else { return XCTFail("\($0)") }
        }
    }

    func testMissingFileThrows() {
        let missing = tmp.appendingPathComponent("nope.png")
        XCTAssertThrowsError(try PDFExporter.export(imageURLs: [missing], to: tmp.appendingPathComponent("x.pdf"))) {
            guard case PDFExportError.unreadableImage(let u) = $0 else { return XCTFail("\($0)") }
            XCTAssertEqual(u, missing)
        }
    }

    func testUnwritableDestinationThrows() throws {
        let urls = try writeJPEGs(1)
        let out = tmp.appendingPathComponent("no/such/dir/x.pdf")
        XCTAssertThrowsError(try PDFExporter.export(imageURLs: urls, to: out)) {
            guard case PDFExportError.writeFailed = $0 else { return XCTFail("\($0)") }
        }
    }

    func testNonWritableDirectoryThrowsAndLeavesNoFile() throws {
        let urls = try writeJPEGs(2)
        let dir = tmp.appendingPathComponent("ro", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path) }
        let out = dir.appendingPathComponent("x.pdf")
        for size in PDFSize.allCases {
            XCTAssertThrowsError(try PDFExporter.export(imageURLs: urls, to: out, size: size)) {
                guard case PDFExportError.writeFailed(let u) = $0 else { return XCTFail("\($0)") }
                XCTAssertEqual(u, out)
            }
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), [])
    }

    func testExportLeavesNoPartialFileAndReplacesExisting() throws {
        let dir = tmp.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let out = dir.appendingPathComponent("book.pdf")
        try Data("old".utf8).write(to: out)
        try PDFExporter.export(imageURLs: try writeJPEGs(2), to: out, size: .balanced)
        try assertPages(out, count: 2)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["book.pdf"])
    }

    func testPageCountValidation() throws {
        let out = tmp.appendingPathComponent("v.pdf")
        try PDFExporter.export(imageURLs: try writeJPEGs(3), to: out)
        XCTAssertTrue(PDFExporter.isValidPDF(out, pageCount: 3))
        XCTAssertFalse(PDFExporter.isValidPDF(out, pageCount: 2))
        // Truncated file (as after a full disk) doesn't parse.
        let data = try Data(contentsOf: out)
        let cut = tmp.appendingPathComponent("cut.pdf")
        try data.prefix(data.count / 2).write(to: cut)
        XCTAssertFalse(PDFExporter.isValidPDF(cut, pageCount: 3))
        XCTAssertFalse(PDFExporter.isValidPDF(tmp.appendingPathComponent("missing.pdf"), pageCount: 3))
    }

    func testUndecodablePageLeavesNoFile() throws {
        // Header kept, body zeroed: fails either when opened or when re-encoded mid-export.
        let dir = tmp.appendingPathComponent("out2", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let good = try writeJPEGs(1)
        var bytes = try Data(contentsOf: good[0])
        let bad = tmp.appendingPathComponent("bad.jpg")
        bytes.replaceSubrange(600..<bytes.count, with: Data(repeating: 0, count: bytes.count - 600))
        try bytes.write(to: bad)
        let out = dir.appendingPathComponent("x.pdf")
XCTAssertThrowsError(try PDFExporter.export(imageURLs: good + [bad], to: out, size: .small)) {
            guard case PDFExportError.unreadableImage(let u) = $0 else { return XCTFail("\($0)") }
            XCTAssertEqual(u, bad)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), [])
    }

    // MARK: Size presets

    /// Tall JPEG pages (taller than both presets' max height): a colour gradient with dark
    /// "text line" bars. Not block noise: resampled 8×8 hard-edged blocks cost JPEG more than the originals.
    func writeTallJPEGs(_ n: Int, width: Int = 1000, height: Int = 2400) throws -> [URL] {
        let sink = try DiskPageSink(directory: tmp.appendingPathComponent("tall"))
        return try (0..<n).map { i in
            let ctx = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            let gradient = try XCTUnwrap(CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                                    colors: [CGColor(red: 1, green: 0.9, blue: 0.7, alpha: 1),
                                                             CGColor(red: 0.3, green: 0.5, blue: CGFloat(i) / 4, alpha: 1)] as CFArray,
                                                    locations: nil))
            ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: height), options: [])
            ctx.setFillColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1)
            for y in stride(from: 40, to: height - 40, by: 36) {
                ctx.fill(CGRect(x: 60, y: y, width: width - 120 - (y * 7 % 300), height: 14))
            }
            return try sink.save(try XCTUnwrap(ctx.makeImage()))
        }
    }

    /// Pixel size of the single image XObject on each page.
    func embeddedImageSizes(_ out: URL) throws -> [(width: Int, height: Int)] {
        let doc = try XCTUnwrap(CGPDFDocument(out as CFURL))
        return try (1...doc.numberOfPages).map { n in
            let dict = try XCTUnwrap(doc.page(at: n)?.dictionary)
            var res: CGPDFDictionaryRef?, xobjects: CGPDFDictionaryRef?
            XCTAssertTrue(CGPDFDictionaryGetDictionary(dict, "Resources", &res))
            XCTAssertTrue(CGPDFDictionaryGetDictionary(try XCTUnwrap(res), "XObject", &xobjects))
            var found: (Int, Int)?
            CGPDFDictionaryApplyBlock(try XCTUnwrap(xobjects), { _, obj, _ in
                var stream: CGPDFStreamRef?
                guard CGPDFObjectGetValue(obj, .stream, &stream), let stream,
                      let sd = CGPDFStreamGetDictionary(stream) else { return true }
                var w: CGPDFInteger = 0, h: CGPDFInteger = 0
                if CGPDFDictionaryGetInteger(sd, "Width", &w), CGPDFDictionaryGetInteger(sd, "Height", &h) {
                    found = (Int(w), Int(h))
                    return false
                }
                return true
            }, nil)
            let (w, h) = try XCTUnwrap(found, "no image on page \(n)")
            return (w, h)
        }
    }

    func testBalancedDownscalesKeepsPageSizeAndIsSmaller() throws {
        let urls = try writeTallJPEGs(3)
        let full = tmp.appendingPathComponent("full.pdf")
        let balanced = tmp.appendingPathComponent("balanced.pdf")
        try PDFExporter.export(imageURLs: urls, to: full, size: .full)
        try PDFExporter.export(imageURLs: urls, to: balanced, size: .balanced)
        // Same mediaBox as .full: 144 dpi on the ORIGINAL 1000×2400 pixels.
        try assertPages(full, count: 3, width: 500, height: 1200)
        try assertPages(balanced, count: 3, width: 500, height: 1200)
        for s in try embeddedImageSizes(balanced) {
            XCTAssertEqual(s.height, 1600)
            XCTAssertEqual(s.width, 667, accuracy: 1)
        }
        let f = try fileSize(full), b = try fileSize(balanced)
        XCTAssertLessThan(Double(b), 0.7 * Double(f), "balanced \(b) B vs full \(f) B")
    }

    func testSmallIsSmallerThanBalanced() throws {
        let urls = try writeTallJPEGs(2)
        let balanced = tmp.appendingPathComponent("b.pdf"), small = tmp.appendingPathComponent("s.pdf")
        try PDFExporter.export(imageURLs: urls, to: balanced, size: .balanced)
        try PDFExporter.export(imageURLs: urls, to: small, size: .small)
        XCTAssertTrue(try embeddedImageSizes(small).allSatisfy { $0.height == 1200 })
        XCTAssertLessThan(try fileSize(small), try fileSize(balanced))
    }

    /// Short pages are re-encoded but never upscaled; pages come out in input order.
    func testPresetKeepsShortPagesAndOrder() throws {
        let out = tmp.appendingPathComponent("short.pdf")
        // More pages than one concurrency chunk, so chunk boundaries are crossed.
        let n = ProcessInfo.processInfo.activeProcessorCount * 2 + 3
        let sink = try DiskPageSink(directory: tmp.appendingPathComponent("order"))
        let urls = try (0..<n).map { i in try sink.save(TestImages.rgbCGImage(100 + i * 2, 432, fill: (200, 20, 40))) }
        try PDFExporter.export(imageURLs: urls, to: out, size: .small)
        let sizes = try embeddedImageSizes(out)
        XCTAssertEqual(sizes.map(\.width), (0..<n).map { 100 + $0 * 2 })
        XCTAssertTrue(sizes.allSatisfy { $0.height == 432 })
    }

    func testPresetPNGInputs() throws {
        let out = tmp.appendingPathComponent("png-small.pdf")
        try PDFExporter.export(imageURLs: try writePNGs(3), to: out, size: .balanced)
        try assertPages(out, count: 3)
        try assertFillsPage(out)
    }

    func testPresetMissingFileThrows() {
        let missing = tmp.appendingPathComponent("nope.jpg")
        XCTAssertThrowsError(try PDFExporter.export(imageURLs: [missing], to: tmp.appendingPathComponent("x.pdf"), size: .small)) {
            guard case PDFExportError.unreadableImage(let u) = $0 else { return XCTFail("\($0)") }
            XCTAssertEqual(u, missing)
        }
    }

    func testPresetValues() {
        XCTAssertEqual(PDFSize.allCases, [.full, .balanced, .small])
        XCTAssertEqual(PDFSize.full.maxPageHeight, nil)
        XCTAssertEqual(PDFSize.balanced.maxPageHeight, 1600)
        XCTAssertEqual(PDFSize.small.maxPageHeight, 1200)
        XCTAssertEqual(PDFSize.full.jpegQuality, 0.85)
        XCTAssertEqual(PDFSize.balanced.jpegQuality, 0.75)
        XCTAssertEqual(PDFSize.small.jpegQuality, 0.65)
        XCTAssertEqual(PDFSize(rawValue: "balanced"), .balanced)
    }
}
