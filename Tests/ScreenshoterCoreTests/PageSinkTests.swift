import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import ScreenshoterCore

final class PageSinkTests: XCTestCase {
    var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("PageSinkTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        // Restore permissions so the OS can clean the temp dir later. No deletion here.
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tmp.path)
    }

    /// Mean absolute pixel difference; JPEG is lossy, so pages are compared approximately.
    func meanDiff(_ a: GrayImage, _ b: GrayImage) -> Double {
        XCTAssertEqual(a.width, b.width)
        XCTAssertEqual(a.height, b.height)
        let total = zip(a.pixels, b.pixels).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }
        return Double(total) / Double(max(a.pixels.count, 1))
    }

    func decode(_ url: URL) throws -> CGImage {
        let src = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try XCTUnwrap(CGImageSourceCreateImageAtIndex(src, 0, nil))
    }

    func testSavesNumberedJPEGsInOrder() throws {
        let dir = tmp.appendingPathComponent("run", isDirectory: true)
        let sink = try DiskPageSink(directory: dir)
        let a = TestImages.rgbCGImage(30, 20, fill: (255, 0, 0))
        let b = TestImages.cgImage(from: TestImages.noisePage(40, 24, seed: 3))
        let u1 = try sink.save(a)
        let u2 = try sink.save(b)
        XCTAssertEqual(u1.lastPathComponent, "0001.jpg")
        XCTAssertEqual(u2.lastPathComponent, "0002.jpg")
        XCTAssertEqual(u1.deletingLastPathComponent().standardizedFileURL, dir.standardizedFileURL)

        for (url, w, h) in [(u1, 30, 20), (u2, 40, 24)] {
            let src = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
            XCTAssertEqual(CGImageSourceGetType(src) as String?, UTType.jpeg.identifier)
            let img = try decode(url)
            XCTAssertEqual(img.width, w)
            XCTAssertEqual(img.height, h)
        }
        // Lossy but close: the gray page round-trips within a small mean error.
        XCTAssertLessThan(meanDiff(try XCTUnwrap(GrayImage(cgImage: try decode(u2))), TestImages.noisePage(40, 24, seed: 3)), 8)
    }

    func testFullSizePageIsOpaqueSRGBJPEG() throws {
        let sink = try DiskPageSink(directory: tmp.appendingPathComponent("run", isDirectory: true))
        let url = try sink.save(TestImages.rgbCGImage(1400, 2096, fill: (200, 30, 40)))
        let src = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any])
        XCTAssertEqual((props[kCGImagePropertyHasAlpha] as? Bool) ?? false, false)
        XCTAssertEqual(props[kCGImagePropertyColorModel] as? String, kCGImagePropertyColorModelRGB as String)
        let img = try decode(url)
        XCTAssertEqual(img.width, 1400)
        XCTAssertEqual(img.height, 2096)
        XCTAssertEqual(img.colorSpace?.name, CGColorSpace.sRGB)
    }

    func testJPEGQualityChangesFileSize() throws {
        let page = TestImages.cgImage(from: TestImages.noisePage(400, 600, seed: 5))
        let low = try DiskPageSink(directory: tmp.appendingPathComponent("low"), jpegQuality: 0.3).save(page)
        let high = try DiskPageSink(directory: tmp.appendingPathComponent("high"), jpegQuality: 0.95).save(page)
        let size = { (u: URL) in try XCTUnwrap(u.resourceValues(forKeys: [.fileSizeKey]).fileSize) }
        XCTAssertLessThan(try size(low), try size(high))
        XCTAssertEqual(try DiskPageSink(directory: tmp.appendingPathComponent("c"), jpegQuality: 7).jpegQuality, 1)
    }

    func testReplaceLastKeepsNumberingAndSetsFilesAside() throws {
        let dir = tmp.appendingPathComponent("run", isDirectory: true)
        let sink = try DiskPageSink(directory: dir)
        for seed in 1...3 { _ = try sink.save(TestImages.cgImage(from: TestImages.noisePage(20, 10, seed: UInt64(seed)))) }
        let merged = TestImages.noisePage(40, 10, seed: 9)
        let url = try sink.replaceLast(2, with: TestImages.cgImage(from: merged))
        XCTAssertEqual(url.lastPathComponent, "0002.jpg")
        XCTAssertLessThan(meanDiff(try XCTUnwrap(GrayImage(cgImage: try decode(url))), merged), 8)
        let fm = FileManager.default
        XCTAssertFalse(fm.fileExists(atPath: dir.appendingPathComponent("0003.jpg").path))
        XCTAssertTrue(fm.fileExists(atPath: dir.appendingPathComponent(".replaced/0003.jpg").path))
        XCTAssertEqual(try sink.save(TestImages.cgImage(from: merged)).lastPathComponent, "0003.jpg")
        XCTAssertThrowsError(try sink.replaceLast(4, with: TestImages.cgImage(from: merged)))
    }

    func testDropLastSetsFilesAside() throws {
        let dir = tmp.appendingPathComponent("run", isDirectory: true)
        let sink = try DiskPageSink(directory: dir)
        for seed in 1...3 { _ = try sink.save(TestImages.cgImage(from: TestImages.noisePage(20, 10, seed: UInt64(seed)))) }
        try sink.dropLast(1)
        let fm = FileManager.default
        XCTAssertFalse(fm.fileExists(atPath: dir.appendingPathComponent("0003.jpg").path))
        XCTAssertTrue(fm.fileExists(atPath: dir.appendingPathComponent(".replaced/0003.jpg").path))
        XCTAssertEqual(try sink.save(TestImages.cgImage(from: TestImages.noisePage(20, 10, seed: 7))).lastPathComponent, "0003.jpg")
        XCTAssertThrowsError(try sink.dropLast(4))
    }

    func testDefaultRunNameFormat() {
        var comps = DateComponents()
        comps.year = 2026; comps.month = 3; comps.day = 7
        comps.hour = 9; comps.minute = 5; comps.second = 4
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone.current
        let date = cal.date(from: comps)!
        XCTAssertEqual(CachePaths.defaultRunName(date: date), "2026-03-07_090504")
    }

    func testRunDirectoryUnderCacheRoot() {
        let root = CachePaths.root()
        XCTAssertEqual(root.lastPathComponent, "google-play-books-downloader")
        XCTAssertTrue(root.path.hasSuffix("Library/Caches/google-play-books-downloader"))
        XCTAssertEqual(CachePaths.runDirectory(name: "t1"), root.appendingPathComponent("t1", isDirectory: true))
    }

    func testUniqueRunDirectory() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        CachePaths.rootOverride = tmp
        defer { CachePaths.rootOverride = nil }
        XCTAssertEqual(CachePaths.root(), tmp)

        // Missing → base name, created.
        let first = try CachePaths.uniqueRunDirectory(name: "run")
        XCTAssertEqual(first, CachePaths.runDirectory(name: "run"))
        XCTAssertTrue(fm.fileExists(atPath: first.path))
        // Same name again (dir exists and is still empty, as for a concurrent capture) → -2, not reused.
        let second = try CachePaths.uniqueRunDirectory(name: "run")
        XCTAssertEqual(second, CachePaths.runDirectory(name: "run-2"))
        XCTAssertTrue(fm.fileExists(atPath: second.path))
        // -3 pre-exists empty → skipped, -4.
        try fm.createDirectory(at: CachePaths.runDirectory(name: "run-3"), withIntermediateDirectories: true)
        XCTAssertEqual(try CachePaths.uniqueRunDirectory(name: "run"), CachePaths.runDirectory(name: "run-4"))
        // The claimed dir is accepted by DiskPageSink.
        let sink = try DiskPageSink(directory: first)
        XCTAssertEqual(try sink.save(TestImages.rgbCGImage(4, 4, fill: (0, 0, 0))).lastPathComponent, "0001.jpg")
    }

    func testUniqueRunDirectoryCreatesRoot() throws {
        let root = tmp.appendingPathComponent("a/b", isDirectory: true)
        CachePaths.rootOverride = root
        defer { CachePaths.rootOverride = nil }
        let dir = try CachePaths.uniqueRunDirectory(name: "run")
        XCTAssertEqual(dir, root.appendingPathComponent("run", isDirectory: true))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.path))
    }

    func testUniqueRunDirectoryConcurrentCallsGetDistinctDirs() throws {
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        CachePaths.rootOverride = tmp
        defer { CachePaths.rootOverride = nil }
        var dirs = [URL?](repeating: nil, count: 16)
        dirs.withUnsafeMutableBufferPointer { out in
            DispatchQueue.concurrentPerform(iterations: out.count) { i in
                out[i] = try? CachePaths.uniqueRunDirectory(name: "same")
            }
        }
        let got = dirs.compactMap { $0 }
        XCTAssertEqual(got.count, 16)
        XCTAssertEqual(Set(got).count, 16)
    }

    func testUniqueRunDirectoryUnwritableRootThrows() throws {
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: tmp.path)
        CachePaths.rootOverride = tmp
        defer { CachePaths.rootOverride = nil }
        XCTAssertThrowsError(try CachePaths.uniqueRunDirectory(name: "run")) {
            guard case PageSinkError.notWritable = $0 else { return XCTFail("\($0)") }
        }
    }

    func testUnwritablePathThrows() throws {
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: tmp.path)
        XCTAssertThrowsError(try DiskPageSink(directory: tmp.appendingPathComponent("sub")))
        XCTAssertThrowsError(try DiskPageSink(directory: tmp))
    }
}
