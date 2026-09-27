import CoreGraphics
import Foundation
import XCTest
@testable import ScreenshoterCore

// MARK: Fakes

/// Virtual time. `sleep` advances it; nothing really waits.
final class FakeClock: SessionClock {
    private(set) var t: TimeInterval = 0
    var onSleep: (() -> Void)?

    func now() -> TimeInterval { t }

    func sleep(_ seconds: Double) async throws {
        t += seconds
        onSleep?()
    }
}

/// Scripted viewer: a window with a page area; each key press shows the next page after `delay`
/// virtual seconds. Preview is 80×60, full is the 4× nearest-neighbour upscale.
final class FakeViewer: WindowCapturer, PageTurner {
    static let previewW = 80, previewH = 60, scale = 4
    static let portrait = PixelRect(x: 24, y: 10, width: 32, height: 44)
    static let landscape = PixelRect(x: 8, y: 10, width: 64, height: 40)

    let clock: FakeClock
    let pageCount: Int
    let pageRect: PixelRect
    var delay: Double = 0.3
    /// Key presses (1-based) the viewer ignores.
    var ignoredPresses: Set<Int> = []
    /// Page index → number of unstable preview frames shown before the page settles.
    var animation: [Int: Int] = [:]
    /// Per-page override of `pageRect`.
    var pageRects: [Int: PixelRect] = [:]
    /// From this key press on (1-based), the viewer flashes a different frame for
    /// `bounceDuration` s and then shows the old page again.
    var bounceFromPress: Int?
    var bounceDuration: Double = 0.3
    private var bounces: [(from: TimeInterval, to: TimeInterval)] = []
    /// After the last page, the next press shows page 0 again (and so on).
    var wraps = false
    /// Pages drawn as a flat light page (no content).
    var blankPages: Set<Int> = []
    /// The Nth `captureFull` call (1-based) throws.
    var failOnFullCapture: Int?
    /// Scrolling-viewer peek: a strip below the page showing the top of the next page.
    var peek: PixelRect?
    /// Page index → seconds a flat loading placeholder shows before the page renders.
    var placeholders: [Int: Double] = [:]
    /// Page index → seconds a cream loading page with a small spinning 5×5 mark shows first.
    /// The mark changes on every preview capture.
    var spinners: [Int: Double] = [:]
    private var spinnerFrame = 0
    /// Blank pages carry a small dark page number near the bottom.
    var blankPageNumbers = false
    /// Pages drawn with smooth, scale-free content (like a scanned cover) instead of noise, so
    /// a slightly different rect gives a slightly different image, as in a re-render.
    var smoothPages: Set<Int> = []
    /// Page index → seconds the page shows only a thin band of content (top 20%, still loading).
    var loadingBands: [Int: Double] = [:]
    /// With `wraps`: after the last page, page 0 comes back drawn at this rect instead.
    var wrapRect: PixelRect?
    /// Page index → reaction delay for the press that shows it (overrides `delay`).
    var delays: [Int: Double] = [:]
    /// Preview column drawn as a flat gutter line (value 60) through the page.
    var gutterX: Int?

    private(set) var turnCount = 0
    private(set) var fullCount = 0
    private var target = 0
    private var schedule: [(time: TimeInterval, index: Int)] = []
    private var shownIndex = 0
    private(set) var animRemaining = 0
    private var animSeed: UInt64 = 10_000
    private var cache: [Int: GrayImage] = [:]

    struct Boom: Error {}

    init(clock: FakeClock, pages: Int, pageRect: PixelRect = FakeViewer.portrait) {
        self.clock = clock
        self.pageCount = pages
        self.pageRect = pageRect
    }

    // PageTurner
    func turnPage() throws {
        turnCount += 1
        if turnCount > 100 { throw Boom() }  // livelock guard: fail fast instead of hanging
        if ignoredPresses.contains(turnCount) { return }
        if let b = bounceFromPress, turnCount >= b {
            let start = clock.now() + delay
            bounces.append((start, start + bounceDuration))
            return
        }
        if target < pageCount - 1 {
            target += 1
            schedule.append((clock.now() + (delays[target] ?? delay), target))
        } else if wraps {
            target = 0
            schedule.append((clock.now() + delay, wrapRect == nil ? 0 : pageCount))
        }
    }

    var displayedIndex: Int {
        schedule.last(where: { $0.time <= clock.now() })?.index ?? 0
    }

    // WindowCapturer
    func captureFull() async throws -> CGImage {
        fullCount += 1
        if fullCount == failOnFullCapture { throw Boom() }
        return TestImages.cgImage(from: FakeViewer.upscale(frame(consume: false)))
    }

    func capturePreview() async throws -> CGImage {
        TestImages.cgImage(from: frame(consume: true))
    }

    private func frame(consume: Bool) -> GrayImage {
        let t = clock.now()
        if bounces.contains(where: { $0.from <= t && t < $0.to }) {
            return window(pageCount + turnCount)  // a page the viewer never commits to
        }
        if let shown = schedule.last(where: { $0.time <= t }), let wait = placeholders[shown.index],
           t < shown.time + wait {
            var img = TestImages.solid(FakeViewer.previewW, FakeViewer.previewH, 30)
            TestImages.drawRect(into: &img, rect: PixelRect(x: 0, y: 0, width: FakeViewer.previewW, height: 4), value: 200)
            TestImages.drawRect(into: &img, rect: rect(shown.index), value: 240)
            return img
        }
        if let shown = schedule.last(where: { $0.time <= t }), let wait = spinners[shown.index],
           t < shown.time + wait {
            if consume { spinnerFrame += 1 }
            var img = TestImages.solid(FakeViewer.previewW, FakeViewer.previewH, 30)
            TestImages.drawRect(into: &img, rect: PixelRect(x: 0, y: 0, width: FakeViewer.previewW, height: 4), value: 200)
            let r = rect(shown.index)
            TestImages.drawRect(into: &img, rect: r, value: 235)
            let cx = r.x + r.width / 2 - 2, cy = r.y + r.height / 2 - 2
            // Bar turning through 4 positions: horizontal, diagonal, vertical, other diagonal.
            for k in 0..<5 {
                let (x, y): (Int, Int)
                switch spinnerFrame % 4 {
                case 0: (x, y) = (k, 2)
                case 1: (x, y) = (k, k)
                case 2: (x, y) = (2, k)
                default: (x, y) = (4 - k, k)
                }
                img[cx + x, cy + y] = 90
            }
            return img
        }
        if let shown = schedule.last(where: { $0.time <= t }), let wait = loadingBands[shown.index],
           t < shown.time + wait {
            var img = TestImages.solid(FakeViewer.previewW, FakeViewer.previewH, 30)
            TestImages.drawRect(into: &img, rect: PixelRect(x: 0, y: 0, width: FakeViewer.previewW, height: 4), value: 200)
            let r = rect(shown.index)
            TestImages.drawNoise(into: &img, rect: PixelRect(x: r.x, y: r.y, width: r.width, height: r.height / 5),
                                 seed: UInt64(shown.index + 1) * 104_729, block: 2)
            return img
        }
        let idx = displayedIndex
        if idx != shownIndex {
            shownIndex = idx
            animRemaining = animation[idx] ?? 0
        }
        if animRemaining > 0 {
            if consume {
                animRemaining -= 1
                animSeed += 1
            }
            var img = window(idx)
            // Top half of the page is still moving.
            let band = PixelRect(x: pageRect.x, y: pageRect.y, width: pageRect.width, height: pageRect.height / 2)
            TestImages.drawNoise(into: &img, rect: band, seed: animSeed, block: 2)
            return img
        }
        return window(idx)
    }

    func window(_ idx: Int) -> GrayImage {
        if let img = cache[idx] { return img }
        var img = TestImages.solid(FakeViewer.previewW, FakeViewer.previewH, 30)
        TestImages.drawRect(into: &img, rect: PixelRect(x: 0, y: 0, width: FakeViewer.previewW, height: 4), value: 200)
        // The wrapped-back page 0 (index pageCount) has page 0's content.
        let seedIdx = idx == pageCount && wrapRect != nil ? 0 : idx
        if blankPages.contains(idx) {
            let r = rect(idx)
            TestImages.drawRect(into: &img, rect: r, value: 240)
            if blankPageNumbers {
                TestImages.drawRect(into: &img, rect: PixelRect(x: r.x + r.width / 2 - 1, y: r.maxY - 4, width: 3, height: 2), value: 40)
            }
        } else if smoothPages.contains(seedIdx) {
            let r = rect(idx)
            for y in r.y..<r.maxY {
                for x in r.x..<r.maxX {
                    let u = (Double(x - r.x) + 0.5) / Double(r.width), v = (Double(y - r.y) + 0.5) / Double(r.height)
                    let f = sin(u * 9 + Double(seedIdx)) * cos(v * 7) + 0.6 * sin((u + v) * 29) + 0.5 * cos(u * 41) * sin(v * 37)
                    img[x, y] = UInt8(max(0, min(255, 128 + 55 * f)))
                }
            }
        } else {
            TestImages.drawNoise(into: &img, rect: rect(idx), seed: UInt64(seedIdx + 1) * 7919, block: 2)
        }
        if let gutterX {
            let r = rect(idx)
            TestImages.drawRect(into: &img, rect: PixelRect(x: gutterX, y: r.y, width: 1, height: r.height), value: 60)
        }
        if let peek {
            TestImages.drawNoise(into: &img, rect: peek, seed: UInt64(idx + 2) * 7919, block: 2)
        }
        cache[idx] = img
        return img
    }

    func rect(_ idx: Int) -> PixelRect {
        if idx == pageCount, let wrapRect { return wrapRect }
        return pageRects[idx] ?? pageRect
    }

    /// Expected full-res page crop for page `idx`.
    func expectedPage(_ idx: Int) -> GrayImage {
        FakeViewer.upscale(window(idx)).cropped(rect(idx).scaled(by: FakeViewer.scale))
    }

    static func upscale(_ g: GrayImage) -> GrayImage {
        let s = scale
        var out = GrayImage(width: g.width * s, height: g.height * s, fill: 0)
        for y in 0..<out.height {
            for x in 0..<out.width { out[x, y] = g[x / s, y / s] }
        }
        return out
    }
}

final class MemorySink: PageSink {
    private(set) var images: [CGImage] = []

    func save(_ image: CGImage) throws -> URL {
        images.append(image)
        return URL(fileURLWithPath: String(format: "/mem/%04d.png", images.count))
    }

    var grays: [GrayImage] { images.map { GrayImage(cgImage: $0)! } }

    private(set) var replaced: [Int] = []

    private(set) var dropped: [Int] = []

    func dropLast(_ count: Int) throws {
        images.removeLast(count)
        dropped.append(count)
    }

    func replaceLast(_ count: Int, with image: CGImage) throws -> URL {
        images.removeLast(count)
        replaced.append(count)
        return try save(image)
    }
}

// MARK: Tests

final class CaptureSessionTests: XCTestCase {
    var clock: FakeClock!
    var sink: MemorySink!
    var logs: [String] = []

    override func setUp() {
        clock = FakeClock()
        sink = MemorySink()
        logs = []
    }

    func makeSession(_ viewer: FakeViewer, config: SessionConfig = SessionConfig()) -> CaptureSession {
        CaptureSession(config: config, capturer: viewer, turner: viewer, clock: clock, sink: sink,
                       log: { [unowned self] in self.logs.append($0) })
    }

    func run(_ viewer: FakeViewer, config: SessionConfig = SessionConfig()) async -> SessionResult {
        await makeSession(viewer, config: config).run()
    }

    /// Play Books layout: shot 0 whole (front cover), shots 1..<n-1 as halves `halves(i)`,
    /// shot n-1 whole (back cover).
    func assertCoverSpreadsCover(_ viewer: FakeViewer, shots n: Int, halves: (Int) -> [PixelRect],
                                 file: StaticString = #filePath, line: UInt = #line) {
        let got = sink.grays
        XCTAssertEqual(got.count, 2 * n - 2, "file count", file: file, line: line)
        guard got.count == 2 * n - 2 else { return }
        XCTAssertTrue(got[0] == viewer.expectedPage(0), "front cover", file: file, line: line)
        for i in 1..<(n - 1) {
            let page = FakeViewer.upscale(viewer.window(i))
            let h = halves(i)
            XCTAssertTrue(got[2 * i - 1] == page.cropped(h[0]), "left half of shot \(i)", file: file, line: line)
            XCTAssertTrue(got[2 * i] == page.cropped(h[1]), "right half of shot \(i)", file: file, line: line)
        }
        XCTAssertTrue(got.last! == viewer.expectedPage(n - 1), "back cover", file: file, line: line)
    }

    func assertPagesMatch(_ viewer: FakeViewer, _ indices: [Int], file: StaticString = #filePath, line: UInt = #line) {
        let got = sink.grays
        XCTAssertEqual(got.count, indices.count, "page count", file: file, line: line)
        for (g, i) in zip(got, indices) {
            XCTAssertTrue(g == viewer.expectedPage(i), "saved page differs from page \(i)", file: file, line: line)
        }
    }

    func testFivePagesThenEnd() async {
        let viewer = FakeViewer(clock: clock, pages: 5)
        let result = await run(viewer)
        XCTAssertEqual(result.reason, .endOfDocument)
        XCTAssertEqual(result.pages.count, 5)
        XCTAssertEqual(viewer.turnCount, 6)
        assertPagesMatch(viewer, [0, 1, 2, 3, 4])
        XCTAssertTrue(logs.contains("reached the end (page stopped changing)"))
    }

    func testSlowViewerSkipsNothing() async {
        let viewer = FakeViewer(clock: clock, pages: 4)
        viewer.delay = 3
        let result = await run(viewer)
        XCTAssertEqual(result.reason, .endOfDocument)
        assertPagesMatch(viewer, [0, 1, 2, 3])
    }

    func testOneIgnoredPressContinues() async {
        let viewer = FakeViewer(clock: clock, pages: 3)
        viewer.ignoredPresses = [2]
        let result = await run(viewer)
        XCTAssertEqual(result.reason, .endOfDocument)
        assertPagesMatch(viewer, [0, 1, 2])
        XCTAssertEqual(viewer.turnCount, 5)
        XCTAssertTrue(logs.contains("no change after key (1/2)"))
    }

    func testBounceBackStopsAfterTwoPresses() async {
        let viewer = FakeViewer(clock: clock, pages: 3)
        viewer.bounceFromPress = 3
        let result = await run(viewer)
        XCTAssertEqual(result.reason, .endOfDocument)
        assertPagesMatch(viewer, [0, 1, 2])
        XCTAssertEqual(viewer.turnCount, 4)
    }

    func testViewerWrapStopsWithoutDuplicate() async {
        let viewer = FakeViewer(clock: clock, pages: 4)
        viewer.wraps = true
        let result = await run(viewer)
        XCTAssertEqual(result.reason, .endOfDocument)
        assertPagesMatch(viewer, [0, 1, 2, 3])
        XCTAssertEqual(viewer.turnCount, 4)
        XCTAssertTrue(logs.contains("page matches page 1 — viewer wrapped, stopping"), "\(logs)")
    }

    func testRepeatedBlankPagesAreSaved() async {
        let viewer = FakeViewer(clock: clock, pages: 5)
        viewer.blankPages = [1, 3]
        let result = await run(viewer)
        XCTAssertEqual(result.reason, .endOfDocument)
        assertPagesMatch(viewer, [0, 1, 2, 3, 4])
        XCTAssertFalse(logs.contains { $0.contains("wrapped") }, "\(logs)")
    }

    func testCapReached() async {
        let viewer = FakeViewer(clock: clock, pages: 10)
        var config = SessionConfig()
        config.maxPages = 3
        let result = await run(viewer, config: config)
        XCTAssertEqual(result.reason, .capReached)
        assertPagesMatch(viewer, [0, 1, 2])
        XCTAssertEqual(viewer.turnCount, 2)
        XCTAssertTrue(logs.contains("hit the page cap (3)"))
    }

    func testCancelDuringSettle() async {
        let viewer = FakeViewer(clock: clock, pages: 4)
        viewer.animation = [2: 1_000]
        let session = makeSession(viewer)
        clock.onSleep = { [unowned viewer] in
            if viewer.displayedIndex == 2, viewer.animRemaining < 990 { session.cancel() }
        }
        let result = await session.run()
        XCTAssertEqual(result.reason, .cancelled)
        assertPagesMatch(viewer, [0, 1])
    }

    func testAnimationWaitsForStable() async {
        let viewer = FakeViewer(clock: clock, pages: 3)
        viewer.animation = [1: 3, 2: 3]
        let result = await run(viewer)
        XCTAssertEqual(result.reason, .endOfDocument)
        assertPagesMatch(viewer, [0, 1, 2])
        XCTAssertFalse(logs.contains { $0.hasPrefix("settle timeout") })
    }

    func testSettleTimeoutStillSaves() async {
        let viewer = FakeViewer(clock: clock, pages: 2)
        // Longer than settleTimeout / pollInterval (15 / 0.15 = 100 polls).
        viewer.animation = [1: 120]
        let result = await run(viewer)
        XCTAssertTrue(logs.contains { $0.hasPrefix("settle timeout") }, "\(logs)")
        XCTAssertEqual(result.reason, .endOfDocument)
        XCTAssertGreaterThanOrEqual(result.pages.count, 2)
        XCTAssertTrue(sink.grays.first == viewer.expectedPage(0))
        // The last shot is the settled page.
        XCTAssertTrue(sink.grays.last == viewer.expectedPage(1))
    }

    func testSplitSpreads() async {
        // All shots landscape: first and last stay whole anyway (covers).
        let viewer = FakeViewer(clock: clock, pages: 3, pageRect: FakeViewer.landscape)
        let result = await run(viewer)
        XCTAssertEqual(result.reason, .endOfDocument)
        XCTAssertEqual(result.pages.count, 4)
        let halves = SpreadSplitter.split(FakeViewer.landscape.scaled(by: FakeViewer.scale))
        assertCoverSpreadsCover(viewer, shots: 3, halves: { _ in halves })
    }

    func testCoverSpreadsBackCoverBook() async {
        // Front cover (portrait), 3 spreads, back cover shown as a zone-wide landscape shot.
        let viewer = FakeViewer(clock: clock, pages: 5, pageRect: FakeViewer.landscape)
        viewer.pageRects = [0: PixelRect(x: 40, y: 10, width: 32, height: 40)]
        let session = makeSession(viewer)
        var replacedWith: [[URL]] = []
        var savedCount = 0
        session.onPagesReplaced = { replacedWith.append($0) }
        session.onPageSaved = { n, _ in savedCount = n }
        let result = await session.run()
        XCTAssertEqual(result.reason, .endOfDocument)
        XCTAssertEqual(result.pages.count, 8)
        let halves = SpreadSplitter.split(FakeViewer.landscape.scaled(by: FakeViewer.scale))
        assertCoverSpreadsCover(viewer, shots: 5, halves: { _ in halves })
        XCTAssertEqual(sink.replaced, [2])
        XCTAssertEqual(savedCount, 9, "onPageSaved saw the split back cover first")
        XCTAssertEqual(replacedWith, [result.pages])
        XCTAssertTrue(logs.contains("last page kept whole (back cover), 8 pages"), "\(logs)")
        XCTAssertEqual(sink.dropped, [], "normal ending: nothing dropped")
    }

    func testTinyEndScreenDroppedBeforeBackCoverMerge() async {
        // Cover, 3 spreads, back cover as a landscape shot (split, then merged), then Play Books'
        // small "next in the series" screen.
        let viewer = FakeViewer(clock: clock, pages: 6, pageRect: FakeViewer.landscape)
        viewer.pageRects = [0: PixelRect(x: 40, y: 10, width: 32, height: 40),
                            5: PixelRect(x: 36, y: 20, width: 8, height: 12)]
        let session = makeSession(viewer)
        var replacedWith: [[URL]] = []
        session.onPagesReplaced = { replacedWith.append($0) }
        let result = await session.run()
        XCTAssertEqual(result.reason, .endOfDocument)
        XCTAssertEqual(sink.dropped, [1])
        XCTAssertEqual(sink.replaced, [2])
        XCTAssertEqual(result.pages.count, 8)
        XCTAssertEqual(replacedWith, [result.pages])
        XCTAssertTrue(logs.contains("dropped end screen (32×48)"), "\(logs)")
        let halves = SpreadSplitter.split(FakeViewer.landscape.scaled(by: FakeViewer.scale))
        assertCoverSpreadsCover(viewer, shots: 5, halves: { _ in halves })
    }

    func testCancelledRunKeepsLastShotSplit() async {
        let viewer = FakeViewer(clock: clock, pages: 5, pageRect: FakeViewer.landscape)
        viewer.animation = [3: 1_000]
        let session = makeSession(viewer)
        var replacedCalls = 0
        session.onPagesReplaced = { _ in replacedCalls += 1 }
        clock.onSleep = { [unowned viewer] in
            if viewer.displayedIndex == 3, viewer.animRemaining < 990 { session.cancel() }
        }
        let result = await session.run()
        XCTAssertEqual(result.reason, .cancelled)
        XCTAssertEqual(result.pages.count, 5, "cover 1 + shots 1-2 split")
        XCTAssertEqual(sink.replaced, [])
        XCTAssertEqual(replacedCalls, 0)
    }

    func testSplitOffKeepsSpreadWhole() async {
        let viewer = FakeViewer(clock: clock, pages: 3, pageRect: FakeViewer.landscape)
        var config = SessionConfig()
        config.splitSpreads = false
        let result = await run(viewer, config: config)
        XCTAssertEqual(result.pages.count, 3)
        assertPagesMatch(viewer, [0, 1, 2])
        XCTAssertEqual(sink.replaced, [])
    }

    func testFirstTurnNoChangeSavesFirstShot() async {
        let viewer = FakeViewer(clock: clock, pages: 1)
        let result = await run(viewer)
        XCTAssertEqual(result.reason, .endOfDocument)
        XCTAssertEqual(result.pages.count, 1)
        XCTAssertEqual(viewer.turnCount, 2)
        XCTAssertNil(result.zone)
        // Trimmed on the whole image: still contains the page.
        let img = sink.images[0]
        XCTAssertGreaterThanOrEqual(img.width, FakeViewer.portrait.width * FakeViewer.scale)
        XCTAssertGreaterThanOrEqual(img.height, FakeViewer.portrait.height * FakeViewer.scale)
    }

    func testCaptureFailure() async {
        let viewer = FakeViewer(clock: clock, pages: 5)
        viewer.failOnFullCapture = 3
        let result = await run(viewer)
        guard case .captureFailed = result.reason else { return XCTFail("\(result.reason)") }
        assertPagesMatch(viewer, [0, 1])
    }

    func testCaptureFailureBeforeZoneKeepsFirstShot() async {
        let viewer = FakeViewer(clock: clock, pages: 5)
        viewer.failOnFullCapture = 2
        let result = await run(viewer)
        guard case .captureFailed = result.reason else { return XCTFail("\(result.reason)") }
        XCTAssertEqual(result.pages.count, 1)
    }

    func testZoneMatchesPageInFullRes() async {
        let viewer = FakeViewer(clock: clock, pages: 3)
        let result = await run(viewer)
        let expected = FakeViewer.portrait.scaled(by: FakeViewer.scale)
        guard let z = result.zone else { return XCTFail("no zone") }
        // detect pads by one 4 px block and snaps to the block grid, so each edge may sit up to
        // 2 blocks (2 × 4 preview px × 4 = 32 full px) outside the page, never inside it.
        let tol = 2 * 4 * FakeViewer.scale
        XCTAssertEqual(z.clamped(width: FakeViewer.previewW * FakeViewer.scale, height: FakeViewer.previewH * FakeViewer.scale), z)
        XCTAssertTrue(z.x <= expected.x && z.y <= expected.y && z.maxX >= expected.maxX && z.maxY >= expected.maxY,
                      "zone \(z) does not contain page \(expected)")
        XCTAssertLessThanOrEqual(expected.x - z.x, tol, "\(z)")
        XCTAssertLessThanOrEqual(expected.y - z.y, tol, "\(z)")
        XCTAssertLessThanOrEqual(z.maxX - expected.maxX, tol, "\(z)")
        XCTAssertLessThanOrEqual(z.maxY - expected.maxY, tol, "\(z)")
    }

    func testZoneRecomputedWhenPageGrows() async {
        let viewer = FakeViewer(clock: clock, pages: 4)
        // Pages 2-3 are wider than the zone learned from pages 0-1.
        viewer.pageRects = [2: FakeViewer.landscape, 3: FakeViewer.landscape]
        var config = SessionConfig()
        config.splitSpreads = false  // tests zone/wrap, not the cover rule
        let result = await run(viewer, config: config)
        XCTAssertEqual(result.reason, .endOfDocument)
        XCTAssertTrue(logs.contains { $0.hasPrefix("zone recomputed") }, "\(logs)")
        assertPagesMatch(viewer, [0, 1, 2, 3])
    }

    func testPreviewAtOtherScaleIsResized() async {
        // Viewer whose preview is full-res: session must scale it down itself.
        final class FullPreviewViewer: WindowCapturer, PageTurner {
            let inner: FakeViewer
            init(_ inner: FakeViewer) { self.inner = inner }
            func captureFull() async throws -> CGImage { try await inner.captureFull() }
            func capturePreview() async throws -> CGImage {
                let p = GrayImage(cgImage: try await inner.capturePreview())!
                return TestImages.cgImage(from: FakeViewer.upscale(p))
            }
            func turnPage() throws { try inner.turnPage() }
        }
        let viewer = FakeViewer(clock: clock, pages: 2)
        let wrapped = FullPreviewViewer(viewer)
        let session = CaptureSession(config: SessionConfig(), capturer: wrapped, turner: wrapped, clock: clock,
                                     sink: sink, log: { _ in })
        let result = await session.run()
        XCTAssertEqual(result.reason, .endOfDocument)
        assertPagesMatch(viewer, [0, 1])
    }

    func testCallbacksReportEachSavedPage() async {
        let viewer = FakeViewer(clock: clock, pages: 3)
        let session = makeSession(viewer)
        var savedCalls: [(Int, URL)] = []
        var statuses: [String] = []
        session.onPageSaved = { savedCalls.append(($0, $1)) }
        session.onStatus = { statuses.append($0) }
        let result = await session.run()
        XCTAssertEqual(result.reason, .endOfDocument)
        XCTAssertEqual(savedCalls.map(\.0), [1, 2, 3])
        XCTAssertEqual(savedCalls.map(\.1), result.pages)
        XCTAssertEqual(statuses.filter { $0.hasPrefix("Saved page") }, ["Saved page 1", "Saved page 2", "Saved page 3"])
        XCTAssertEqual(statuses.filter { $0 == "Turning page…" }.count, viewer.turnCount)
        // One settle wait per detected change: pages 2 and 3.
        XCTAssertEqual(statuses.filter { $0 == "Waiting for the page to settle…" }.count, 2)
        XCTAssertEqual(statuses.first, "Turning page…")
    }

    func testPeekStripBelowPageIsNeverSaved() async {
        // Scrolling viewer: 7 preview px (28 full px) of dark gap, then a strip of the next page.
        let page = PixelRect(x: 20, y: 6, width: 40, height: 40)
        let viewer = FakeViewer(clock: clock, pages: 3, pageRect: page)
        viewer.peek = PixelRect(x: 20, y: page.maxY + 7, width: 40, height: 3)
        let result = await run(viewer)
        XCTAssertEqual(result.reason, .endOfDocument)
        assertPagesMatch(viewer, [0, 1, 2])
        guard let z = result.zone else { return XCTFail("no zone") }
        XCTAssertLessThanOrEqual(z.maxY, viewer.peek!.y * FakeViewer.scale, "zone \(z) reaches the strip")
    }

    func testSplitSpreadsCutsAtOffCenterGutter() async {
        let viewer = FakeViewer(clock: clock, pages: 4, pageRect: FakeViewer.landscape)
        viewer.gutterX = 42  // center is preview column 40
        let result = await run(viewer)
        XCTAssertEqual(result.pages.count, 6)
        let full = FakeViewer.landscape.scaled(by: FakeViewer.scale)
        assertCoverSpreadsCover(viewer, shots: 4, halves: { i in
            // The splitter on the full shot must agree with the session, which runs it on the crop.
            let halves = SpreadSplitter.split(full, in: FakeViewer.upscale(viewer.window(i)))
            XCTAssertNotEqual(halves, SpreadSplitter.split(full), "gutter not found")
            XCTAssertEqual(halves[1].x, 42 * FakeViewer.scale, accuracy: 4)
            return halves
        })
    }

    func testLoadingPlaceholderIsNotSaved() async {
        // Pages 1 (zone not yet known) and 2 (zone known) show a blank placeholder for 1 s.
        let viewer = FakeViewer(clock: clock, pages: 4)
        viewer.placeholders = [1: 1.0, 2: 1.0]
        let result = await run(viewer)
        XCTAssertEqual(result.reason, .endOfDocument)
        assertPagesMatch(viewer, [0, 1, 2, 3])
        XCTAssertFalse(logs.contains { $0.hasPrefix("blank page") }, "\(logs)")
    }

    func testRealBlankPageKeptWithinBlankWait() async {
        let viewer = FakeViewer(clock: clock, pages: 5)
        viewer.blankPages = [3]
        let session = makeSession(viewer)
        var saveTimes: [TimeInterval] = []
        session.onPageSaved = { [unowned self] _, _ in saveTimes.append(self.clock.now()) }
        let result = await session.run()
        XCTAssertEqual(result.reason, .endOfDocument)
        assertPagesMatch(viewer, [0, 1, 2, 3, 4])
        XCTAssertTrue(logs.contains("blank page 4 kept"), "\(logs)")
        // Pages 1 and 2 are saved together (first shot + zone), so compare against page 2 → 3.
        // The blank page adds at most blankWait plus one poll to a normal page gap.
        let normal = saveTimes[2] - saveTimes[1]
        XCTAssertLessThanOrEqual(saveTimes[3] - saveTimes[2], normal + SessionConfig().blankWait + 0.15 + 1e-9)
    }

    func testSlowViewerSevenSecondsNoSkip() async {
        let viewer = FakeViewer(clock: clock, pages: 3)
        viewer.delays = [1: 7]
        let result = await run(viewer)
        XCTAssertEqual(result.reason, .endOfDocument)
        assertPagesMatch(viewer, [0, 1, 2])
        // One press per page (2), then two presses with no change at the end.
        XCTAssertEqual(viewer.turnCount, 4)
        XCTAssertFalse(logs.prefix(while: { !$0.hasPrefix("page 3") }).contains("no change after key (1/2)"), "\(logs)")
    }

    func testWrapToShiftedCoverStopsAfterZoneRecompute() async {
        // The viewer wraps to the cover shown at another spot, so the zone is recomputed right
        // at the wrap. Earlier shots must be compared on the new zone.
        let viewer = FakeViewer(clock: clock, pages: 4)
        viewer.wraps = true
        viewer.wrapRect = PixelRect(x: FakeViewer.portrait.x + 16, y: FakeViewer.portrait.y,
                                    width: FakeViewer.portrait.width, height: FakeViewer.portrait.height)
        let result = await run(viewer)
        XCTAssertEqual(result.reason, .endOfDocument)
        assertPagesMatch(viewer, [0, 1, 2, 3])
        XCTAssertTrue(logs.contains { $0.hasPrefix("zone recomputed") }, "\(logs)")
        XCTAssertTrue(logs.contains("page matches page 1 — viewer wrapped, stopping"), "\(logs)")
        XCTAssertEqual(viewer.turnCount, 4)
    }

    func testLoadingBandSpreadWaitsForFullPages() async {
        // Spread still loading: only a thin band (top 20%) of content for 1 s, then full pages.
        let viewer = FakeViewer(clock: clock, pages: 3, pageRect: FakeViewer.landscape)
        viewer.loadingBands = [1: 1.0, 2: 1.0]
        let result = await run(viewer)
        XCTAssertEqual(result.reason, .endOfDocument)
        XCTAssertEqual(result.pages.count, 4)
        let halves = SpreadSplitter.split(FakeViewer.landscape.scaled(by: FakeViewer.scale))
        assertCoverSpreadsCover(viewer, shots: 3, halves: { _ in halves })
        XCTAssertFalse(logs.contains { $0.contains("page") && $0.hasSuffix("kept") }, "\(logs)")
    }

    func testSpinnerPlaceholderIsNotSaved() async {
        // Cream loading page with a small spinning mark for 2 s, then the real page.
        let viewer = FakeViewer(clock: clock, pages: 4)
        viewer.spinners = [1: 2.0, 2: 2.0]
        let result = await run(viewer)
        XCTAssertEqual(result.reason, .endOfDocument)
        assertPagesMatch(viewer, [0, 1, 2, 3])
        XCTAssertFalse(logs.contains { $0.hasSuffix("kept") || $0.hasPrefix("settle timeout") }, "\(logs)")
    }

    func testBlankPageWithPageNumberKept() async {
        let viewer = FakeViewer(clock: clock, pages: 4)
        viewer.blankPages = [2]
        viewer.blankPageNumbers = true
        let result = await run(viewer)
        XCTAssertEqual(result.reason, .endOfDocument)
        assertPagesMatch(viewer, [0, 1, 2, 3])
        XCTAssertTrue(logs.contains("blank page 3 kept"), "\(logs)")
    }

    func testTwoUpWrapToCoverStopsWithoutSavingCoverTwice() async {
        // 2-up viewer: cover alone on the right half, then spreads. On the wrap the cover comes
        // back re-rendered 1 px smaller (like a re-layout), so it is close but not identical.
        let spread = FakeViewer.landscape
        let cover = PixelRect(x: spread.x + spread.width / 2, y: spread.y, width: spread.width / 2, height: spread.height)
        let viewer = FakeViewer(clock: clock, pages: 4, pageRect: spread)
        viewer.pageRects = [0: cover]
        viewer.smoothPages = [0]
        viewer.wraps = true
        viewer.wrapRect = PixelRect(x: cover.x, y: cover.y, width: cover.width - 1, height: cover.height - 1)
        var config = SessionConfig()
        config.splitSpreads = false  // tests zone/wrap, not the cover rule
        let result = await run(viewer, config: config)
        XCTAssertEqual(result.reason, .endOfDocument)
        assertPagesMatch(viewer, [0, 1, 2, 3])
        XCTAssertTrue(logs.contains("page matches page 1 — viewer wrapped, stopping"), "\(logs)")
    }

    func testPeekStripMergedIntoZoneIsCutBySegment() async {
        // 5 preview px gap: `detect` merges page and strip into one zone (known limit, see
        // PageZoneTests). `segment` still cuts at the dark gap rows.
        let page = PixelRect(x: 20, y: 6, width: 40, height: 40)
        let viewer = FakeViewer(clock: clock, pages: 3, pageRect: page)
        viewer.peek = PixelRect(x: 20, y: page.maxY + 5, width: 40, height: 4)
        let result = await run(viewer)
        XCTAssertEqual(result.reason, .endOfDocument)
        guard let z = result.zone else { return XCTFail("no zone") }
        XCTAssertGreaterThan(z.maxY, viewer.peek!.y * FakeViewer.scale, "zone \(z) should include the strip here")
        assertPagesMatch(viewer, [0, 1, 2])
    }
}
