import XCTest
@testable import ScreenshoterCore

final class SpreadSplitterTests: XCTestCase {
    func testLandscapeIsSpreadAndSplitsInHalf() {
        let r = PixelRect(x: 0, y: 0, width: 1000, height: 600)
        XCTAssertTrue(SpreadSplitter.isSpread(r))
        XCTAssertEqual(SpreadSplitter.split(r), [
            PixelRect(x: 0, y: 0, width: 500, height: 600),
            PixelRect(x: 500, y: 0, width: 500, height: 600),
        ])
    }

    func testSplitIsOffsetByOrigin() {
        XCTAssertEqual(SpreadSplitter.split(PixelRect(x: 10, y: 20, width: 1000, height: 600)), [
            PixelRect(x: 10, y: 20, width: 500, height: 600),
            PixelRect(x: 510, y: 20, width: 500, height: 600),
        ])
    }

    func testOddWidthGivesLeftTheFloor() {
        XCTAssertEqual(SpreadSplitter.split(PixelRect(x: 0, y: 0, width: 1001, height: 600)), [
            PixelRect(x: 0, y: 0, width: 500, height: 600),
            PixelRect(x: 500, y: 0, width: 501, height: 600),
        ])
    }

    func testPortraitIsNotSpread() {
        XCTAssertFalse(SpreadSplitter.isSpread(PixelRect(x: 0, y: 0, width: 600, height: 800)))
    }

    func testSlightlyWideIsNotSpread() {
        XCTAssertFalse(SpreadSplitter.isSpread(PixelRect(x: 0, y: 0, width: 1100, height: 1000)))
    }

    // MARK: split(_:in:) — gutter search

    /// Asserts a 2-rect split of `r` whose cut sits within `tol` px of `x`.
    func assertCut(_ rects: [PixelRect], _ r: PixelRect, at x: Int, tol: Int = 1,
                   file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(rects.count, 2, file: file, line: line)
        guard rects.count == 2 else { return }
        XCTAssertEqual(rects[0].x, r.x, file: file, line: line)
        XCTAssertEqual(rects[0].maxX, rects[1].x, file: file, line: line)
        XCTAssertEqual(rects[1].maxX, r.maxX, file: file, line: line)
        XCTAssertTrue(rects.allSatisfy { $0.y == r.y && $0.height == r.height }, file: file, line: line)
        XCTAssertLessThanOrEqual(abs(rects[1].x - x), tol, "cut at \(rects[1].x), want \(x)", file: file, line: line)
    }

    /// Text-like content: dark 3 px strokes on random columns of `rect`, every 6th row band.
    func drawText(into img: inout GrayImage, rect: PixelRect, seed: UInt64) {
        var s = seed
        for band in stride(from: rect.y, to: rect.maxY - 4, by: 12) {
            var x = rect.x
            while x < rect.maxX - 3 {
                s = s &* 6364136223846793005 &+ 1442695040888963407
                if (s >> 33) % 2 == 0 { TestImages.drawRect(into: &img, rect: PixelRect(x: x, y: band, width: 3, height: 7), value: 40) }
                x += 5
            }
        }
    }

    func testGutterLineInSymmetricSpread() {
        // Page area offset in a bigger image: r's coordinates are image coordinates.
        var img = TestImages.solid(1100, 700, 30)
        let r = PixelRect(x: 40, y: 50, width: 1000, height: 600)
        TestImages.drawRect(into: &img, rect: r, value: 245)
        drawText(into: &img, rect: PixelRect(x: 100, y: 100, width: 380, height: 500), seed: 1)
        drawText(into: &img, rect: PixelRect(x: 600, y: 100, width: 380, height: 500), seed: 2)
        let gutter = 40 + 510  // 1 px grey line, 10 px right of center
        TestImages.drawRect(into: &img, rect: PixelRect(x: gutter, y: r.y, width: 1, height: r.height), value: 180)
        assertCut(SpreadSplitter.split(r, in: img), r, at: gutter)
    }

    func testAsymmetricSpreadCutsAtEdge() {
        // Left page 46% wide (slightly darker), right page 54%: the edge is 40 px left of center.
        var img = TestImages.solid(1000, 600, 0)
        let r = img.bounds
        TestImages.drawRect(into: &img, rect: PixelRect(x: 0, y: 0, width: 460, height: 600), value: 225)
        TestImages.drawRect(into: &img, rect: PixelRect(x: 460, y: 0, width: 540, height: 600), value: 250)
        drawText(into: &img, rect: PixelRect(x: 40, y: 40, width: 380, height: 520), seed: 3)
        drawText(into: &img, rect: PixelRect(x: 540, y: 40, width: 420, height: 520), seed: 4)
        assertCut(SpreadSplitter.split(r, in: img), r, at: 460)
    }

    func testWhitePageCreamPageThinGreyLine() {
        // Google Play Books: plain white left page | cream right page with content, thin grey line
        // between them, 2 px wide (Retina) and 25 px right of center.
        var img = TestImages.solid(1000, 600, 255)
        let r = img.bounds
        let line = 525
        TestImages.drawRect(into: &img, rect: PixelRect(x: line, y: 0, width: 475, height: 600), value: 244)
        TestImages.drawRect(into: &img, rect: PixelRect(x: line, y: 0, width: 2, height: 600), value: 210)
        drawText(into: &img, rect: PixelRect(x: 580, y: 40, width: 380, height: 520), seed: 5)
        assertCut(SpreadSplitter.split(r, in: img), r, at: line)
    }

    func testNoGutterFallsBackToCenter() {
        let r = PixelRect(x: 0, y: 0, width: 1000, height: 600)
        let img = TestImages.noisePage(1000, 600, seed: 42)
        XCTAssertEqual(SpreadSplitter.split(r, in: img), SpreadSplitter.split(r))
    }

    func testTextAcrossCenterFallsBackToCenter() {
        // Uniform page with text running through the center, no gutter.
        var img = TestImages.solid(1000, 600, 250)
        let r = img.bounds
        drawText(into: &img, rect: PixelRect(x: 20, y: 20, width: 960, height: 560), seed: 6)
        XCTAssertEqual(SpreadSplitter.split(r, in: img), SpreadSplitter.split(r))
    }

    func testGutterOutsideWindowFallsBackToCenter() {
        // An edge at 30% is outside ±6% of center: ignored.
        var img = TestImages.solid(1000, 600, 250)
        let r = img.bounds
        TestImages.drawRect(into: &img, rect: PixelRect(x: 0, y: 0, width: 300, height: 600), value: 200)
        XCTAssertEqual(SpreadSplitter.split(r, in: img), SpreadSplitter.split(r))
    }
}
