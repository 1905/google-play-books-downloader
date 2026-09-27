import XCTest
@testable import ScreenshoterCore

final class PageZoneTests: XCTestCase {
    // Synthetic window at quarter scale: toolbar, dark backdrop, a noise page.
    let page = PixelRect(x: 120, y: 40, width: 160, height: 240)

    func window(pageSeed: UInt64, pageRect: PixelRect? = nil, counter: UInt8? = nil) -> GrayImage {
        var img = TestImages.solid(400, 300, 30)
        TestImages.drawRect(into: &img, rect: PixelRect(x: 0, y: 0, width: 400, height: 20), value: 200)
        if let counter {
            TestImages.drawRect(into: &img, rect: PixelRect(x: 300, y: 6, width: 20, height: 8), value: counter)
        }
        TestImages.drawNoise(into: &img, rect: pageRect ?? page, seed: pageSeed)
        return img
    }

    func assertNear(_ r: PixelRect?, _ expected: PixelRect, tol: Int = 4,
                    file: StaticString = #filePath, line: UInt = #line) {
        guard let r else { return XCTFail("nil zone", file: file, line: line) }
        XCTAssertLessThanOrEqual(abs(r.x - expected.x), tol, "x \(r)", file: file, line: line)
        XCTAssertLessThanOrEqual(abs(r.y - expected.y), tol, "y \(r)", file: file, line: line)
        XCTAssertLessThanOrEqual(abs(r.maxX - expected.maxX), tol, "maxX \(r)", file: file, line: line)
        XCTAssertLessThanOrEqual(abs(r.maxY - expected.maxY), tol, "maxY \(r)", file: file, line: line)
    }

    // MARK: detect

    func testDetectFindsPage() {
        let zone = PageZone.detect(before: window(pageSeed: 1), after: window(pageSeed: 2))
        assertNear(zone, page)
    }

    func testDetectIgnoresToolbarCounter() {
        let plain = PageZone.detect(before: window(pageSeed: 1), after: window(pageSeed: 2))
        let withCounter = PageZone.detect(before: window(pageSeed: 1, counter: 60),
                                          after: window(pageSeed: 2, counter: 250))
        XCTAssertNotNil(plain)
        XCTAssertEqual(plain, withCounter)
    }

    func testDetectSpreadWithUnchangedGutterCoversBothPages() {
        // Two facing pages, 12 px gutter of backdrop between them that never changes.
        let left = PixelRect(x: 60, y: 40, width: 136, height: 240)
        let right = PixelRect(x: 208, y: 40, width: 136, height: 240)
        func spread(_ seed: UInt64, counter: UInt8) -> GrayImage {
            var img = window(pageSeed: seed, pageRect: left, counter: counter)
            TestImages.drawNoise(into: &img, rect: right, seed: seed &+ 100)
            return img
        }
        let zone = PageZone.detect(before: spread(1, counter: 60), after: spread(2, counter: 250))
        // Expected: union of both pages, padded by one 4 px block → ±1 block tolerance.
        assertNear(zone, PixelRect(x: left.x, y: left.y, width: right.maxX - left.x, height: left.height))
    }

    func testDetectIdenticalIsNil() {
        let img = window(pageSeed: 1)
        XCTAssertNil(PageZone.detect(before: img, after: img))
    }

    func testDetectSmallChangeIsNil() {
        let before = TestImages.solid(400, 300, 30)
        var after = before
        // 80×75 = 6000 px = 5% of 120000.
        TestImages.drawRect(into: &after, rect: PixelRect(x: 160, y: 100, width: 80, height: 75), value: 220)
        XCTAssertNil(PageZone.detect(before: before, after: after))
    }

    func testDetectCoversUnionWhenCoverIsSmaller() {
        let cover = PixelRect(x: 140, y: 60, width: 120, height: 200)
        let zone = PageZone.detect(before: window(pageSeed: 1, pageRect: cover), after: window(pageSeed: 2))
        assertNear(zone, page)
    }

    func testDetectZoneIsClampedToImage() {
        let full = PixelRect(x: 0, y: 20, width: 400, height: 280)
        let zone = PageZone.detect(before: window(pageSeed: 1, pageRect: full),
                                   after: window(pageSeed: 2, pageRect: full))
        assertNear(zone, full)
        if let zone {
            XCTAssertEqual(zone.clamped(width: 400, height: 300), zone)
        }
    }

    // MARK: detect — scrolling viewer peek

    /// Google Play Books (scrolling): the page, a dark gap, then a thin strip showing the top of
    /// the next spread. Both change on a page turn.
    func peekWindow(_ seed: UInt64, page: PixelRect, strip: PixelRect) -> GrayImage {
        var img = TestImages.solid(600, 640, 20)
        TestImages.drawNoise(into: &img, rect: page, seed: seed)
        TestImages.drawNoise(into: &img, rect: strip, seed: seed &+ 500)
        return img
    }

    func testDetectExcludesPeekStripBelowPage() {
        let page = PixelRect(x: 100, y: 20, width: 400, height: 520)
        let strip = PixelRect(x: 100, y: page.maxY + 20, width: 400, height: 30)
        let zone = PageZone.detect(before: peekWindow(1, page: page, strip: strip),
                                   after: peekWindow(2, page: page, strip: strip))
        assertNear(zone, page)
        if let zone { XCTAssertLessThanOrEqual(zone.maxY, strip.y, "zone \(zone) reaches the strip") }
    }

    /// Page at `offset` px below a block boundary, strip `gap` px below the page.
    func assertPeekExcluded(offset: Int, gap: Int, file: StaticString = #filePath, line: UInt = #line) {
        let page = PixelRect(x: 100, y: 20 + offset, width: 400, height: 520)
        let strip = PixelRect(x: 100, y: page.maxY + gap, width: 400, height: 8)
        let zone = PageZone.detect(before: peekWindow(1, page: page, strip: strip),
                                   after: peekWindow(2, page: page, strip: strip))
        // Block snap + one block of padding: up to 2 blocks outside the page.
        assertNear(zone, page, tol: 8, file: file, line: line)
        if let zone {
            XCTAssertLessThanOrEqual(zone.maxY, strip.y, "offset \(offset): zone \(zone) reaches the strip",
                                     file: file, line: line)
        }
    }

    func testDetectExcludesPeekStripAtPreviewScale() {
        // Preview is full ÷ 4, so a 28 px gap becomes 7 px: always one whole unchanged block row.
        for offset in 0..<4 { assertPeekExcluded(offset: offset, gap: 7) }
    }

    func testDetectPeekStripFiveBlockGapKnownLimit() {
        // KNOWN LIMIT: a 5 px preview gap (20 full px) holds no whole 4 px block row for some grid
        // alignments; page and strip blocks then touch and merge. Offsets 0 and 3 pass today.
        assertPeekExcluded(offset: 0, gap: 5)
        assertPeekExcluded(offset: 3, gap: 5)
        XCTExpectFailure("5 px gap merges with the page when no whole block row fits in it") {
            assertPeekExcluded(offset: 1, gap: 5)
            assertPeekExcluded(offset: 2, gap: 5)
        }
    }

    // MARK: trim

    func backdropWithPage() -> GrayImage {
        var img = TestImages.solid(400, 300, 30)
        TestImages.drawNoise(into: &img, rect: page, seed: 5)
        return img
    }

    func testTrimRemovesBackdropBorder() {
        let zone = PixelRect(x: page.x - 12, y: page.y - 12, width: page.width + 24, height: page.height + 24)
        assertNear(PageZone.trim(backdropWithPage(), zone: zone), page, tol: 2)
    }

    func testTrimLeavesPageTouchingEdgesUnchanged() {
        XCTAssertEqual(PageZone.trim(backdropWithPage(), zone: page), page)
    }

    func testTrimStopsAtMaxFractionPerSide() {
        let zone = PixelRect(x: 100, y: 100, width: 100, height: 100)
        XCTAssertEqual(PageZone.trim(TestImages.solid(400, 300, 30), zone: zone),
                       PixelRect(x: 175, y: 175, width: 20, height: 20))
    }

    func testTrimCoverInRightHalfOfSpreadZone() {
        // 2-up viewer: zone is spread-wide, the cover fills only the right ~45%.
        var img = TestImages.solid(220, 120, 0)
        let cover = PixelRect(x: 120, y: 10, width: 90, height: 100)
        for y in cover.y..<cover.maxY {  // checker, like real page content (not a flat fill)
            for x in cover.x..<cover.maxX { img[x, y] = (x / 2 + y / 2) % 2 == 0 ? 200 : 100 }
        }
        let zone = PixelRect(x: 10, y: 10, width: 200, height: 100)
        XCTAssertEqual(PageZone.trim(img, zone: zone), cover)
    }

    func testTrimGreyTopStripAndBlackSides() {
        // Real case (Safari on macOS 26): a grey strip at the zone top, black backdrop at the sides.
        var img = TestImages.solid(200, 120, 0)
        TestImages.drawRect(into: &img, rect: PixelRect(x: 0, y: 0, width: 200, height: 8), value: 40)
        let page = PixelRect(x: 110, y: 8, width: 80, height: 104)
        for y in page.y..<page.maxY { for x in page.x..<page.maxX { img[x, y] = (x / 2 + y / 2) % 2 == 0 ? 200 : 100 } }
        XCTAssertEqual(PageZone.trim(img, zone: PixelRect(x: 0, y: 0, width: 200, height: 120)), page)
    }

    func testTrimGreyTopStripAndNoisyBottomCorners() {
        // Real case (Safari on macOS 26): grey strip fills both top corners, bottom corners sit on
        // a non-uniform control bar, black backdrop only at the sides. Needs a second pass.
        var img = TestImages.solid(200, 120, 0)
        TestImages.drawRect(into: &img, rect: PixelRect(x: 0, y: 0, width: 200, height: 8), value: 40)
        for x in 0..<200 { for y in 116..<120 { img[x, y] = (x / 2) % 2 == 0 ? 90 : 10 } }
        let page = PixelRect(x: 110, y: 8, width: 80, height: 104)
        for y in page.y..<page.maxY { for x in page.x..<page.maxX { img[x, y] = (x / 2 + y / 2) % 2 == 0 ? 200 : 100 } }
        let r = PageZone.trim(img, zone: PixelRect(x: 0, y: 0, width: 200, height: 120))
        XCTAssertEqual(r.x, page.x); XCTAssertEqual(r.maxX, page.maxX); XCTAssertEqual(r.y, page.y)
    }

    func testTrimKeepsPageWhiteMargins() {
        // Dark backdrop at the zone edges; the page has uniform white margins around content.
        var img = TestImages.solid(200, 200, 0)
        let page = PixelRect(x: 40, y: 30, width: 120, height: 140)
        TestImages.drawRect(into: &img, rect: page, value: 250)
        for y in 50..<150 { for x in 60..<140 { img[x, y] = (x / 2 + y / 2) % 2 == 0 ? 200 : 60 } }
        XCTAssertEqual(PageZone.trim(img, zone: PixelRect(x: 0, y: 0, width: 200, height: 200)), page)
    }

    // MARK: segment

    /// Google Play Books-like window at preview-ish scale: dark backdrop (22), a 2-up spread
    /// (white left page, cream right page, thin grey gutter), a dark gap, then the top of the next
    /// spread peeking in and clipped by the window bottom. The zone is what `detect` gives: the
    /// changed area padded by a few px inside the window at top/left/right, clamped at the bottom.
    let spreadRect = PixelRect(x: 40, y: 30, width: 620, height: 440)
    let playZone = PixelRect(x: 30, y: 20, width: 640, height: 540)

    func playBooks(leftBlank: Bool = false, cover: Bool = false) -> GrayImage {
        var img = TestImages.solid(700, 560, 22)
        let s = spreadRect
        let left = PixelRect(x: s.x, y: s.y, width: s.width / 2, height: s.height)
        let right = PixelRect(x: s.x + s.width / 2, y: s.y, width: s.width / 2, height: s.height)
        if !cover {
            TestImages.drawRect(into: &img, rect: left, value: 252)
            if leftBlank {  // verso: only a page number
                TestImages.drawRect(into: &img, rect: PixelRect(x: left.x + 150, y: left.maxY - 20, width: 10, height: 6), value: 60)
            } else {
                for i in 0..<20 { TestImages.drawRect(into: &img, rect: PixelRect(x: left.x + 30, y: left.y + 30 + i * 19, width: 240, height: 6), value: 50) }
            }
            TestImages.drawRect(into: &img, rect: PixelRect(x: right.x - 1, y: s.y, width: 2, height: s.height), value: 200)
        }
        TestImages.drawRect(into: &img, rect: right, value: 240)
        TestImages.drawNoise(into: &img, rect: PixelRect(x: right.x + 30, y: right.y + 30, width: 250, height: 380), seed: 9)
        // Next spread: 20 px dark gap, then its top (white | cream), clipped at the bottom.
        TestImages.drawRect(into: &img, rect: PixelRect(x: s.x, y: s.maxY + 20, width: s.width / 2, height: 100), value: 252)
        TestImages.drawRect(into: &img, rect: PixelRect(x: s.x + s.width / 2, y: s.maxY + 20, width: s.width / 2, height: 100), value: 240)
        TestImages.drawRect(into: &img, rect: PixelRect(x: s.x + 60, y: s.maxY + 50, width: 200, height: 8), value: 50)
        return img
    }

    func testSegmentDropsPeekingNextSpread() {
        let r = PageZone.segment(playBooks(), zone: playZone)
        XCTAssertEqual(r, spreadRect)
    }

    func testSegmentCoverInRightHalfDropsDarkHalf() {
        let cover = PixelRect(x: spreadRect.x + spreadRect.width / 2, y: spreadRect.y,
                              width: spreadRect.width / 2, height: spreadRect.height)
        XCTAssertEqual(PageZone.segment(playBooks(cover: true), zone: playZone), cover)
    }

    func testSegmentAlmostBlankLeftPageKeepsBothPages() {
        XCTAssertEqual(PageZone.segment(playBooks(leftBlank: true), zone: playZone), spreadRect)
    }

    func testSegmentFirstShotSpreadWithZoneEdgesInPaperMargins() {
        // Real case (pb_test2, first shot mid-book): the window is exactly as wide as the spread;
        // the zone from the first page turn cut through the unchanged white margins: its left
        // edge on the window border, its right edge inside the right page's margin. Paper white
        // was then seen on two edges and taken as backdrop, and the light right page (sparse
        // art) fell apart into columns of "backdrop": only the left page was saved.
        var img = TestImages.solid(700, 600, 22)
        let spread = PixelRect(x: 0, y: 40, width: 700, height: 500)
        TestImages.drawRect(into: &img, rect: spread, value: 253)
        TestImages.drawNoise(into: &img, rect: PixelRect(x: 30, y: 70, width: 290, height: 440), seed: 4)
        for i in 0..<6 {  // right page: sparse line art on white
            TestImages.drawRect(into: &img, rect: PixelRect(x: 380 + i * 45, y: 90 + i * 60, width: 30, height: 3), value: 40)
            TestImages.drawRect(into: &img, rect: PixelRect(x: 380 + i * 45, y: 90 + i * 60, width: 3, height: 30), value: 40)
        }
        let zone = PixelRect(x: 0, y: 30, width: 680, height: 530)
        XCTAssertEqual(PageZone.segment(img, zone: zone), PixelRect(x: 0, y: 40, width: 680, height: 500))
    }

    func testSegmentGreyTopStripAndBlackSides() {
        // Same image as testTrimGreyTopStripAndBlackSides; zone = whole image. The grey strip is
        // seen on the top edge only (weak) and peeled off the page it touches.
        var img = TestImages.solid(200, 120, 0)
        TestImages.drawRect(into: &img, rect: PixelRect(x: 0, y: 0, width: 200, height: 8), value: 40)
        let page = PixelRect(x: 110, y: 8, width: 80, height: 104)
        for y in page.y..<page.maxY { for x in page.x..<page.maxX { img[x, y] = (x / 2 + y / 2) % 2 == 0 ? 200 : 100 } }
        XCTAssertEqual(PageZone.segment(img, zone: img.bounds), page)
    }

    func testSegmentMatchesTrimOnPlainBackdrop() {
        let zone = PixelRect(x: page.x - 12, y: page.y - 12, width: page.width + 24, height: page.height + 24)
        XCTAssertEqual(PageZone.segment(backdropWithPage(), zone: zone), page)
        XCTAssertEqual(PageZone.segment(backdropWithPage(), zone: page), page)  // no backdrop: trim fallback
    }

    func testSegmentKeepsPageWhiteMargins() {
        var img = TestImages.solid(200, 200, 0)
        let page = PixelRect(x: 40, y: 30, width: 120, height: 140)
        TestImages.drawRect(into: &img, rect: page, value: 250)
        for y in 50..<150 { for x in 60..<140 { img[x, y] = (x / 2 + y / 2) % 2 == 0 ? 200 : 60 } }
        XCTAssertEqual(PageZone.segment(img, zone: PixelRect(x: 0, y: 0, width: 200, height: 200)), page)
    }

    func testExceedsAtMarginBoundary() {
        let zone = PixelRect(x: 100, y: 100, width: 100, height: 100)
        let m = 8
        XCTAssertFalse(PageZone.exceeds(zone, zone: zone, margin: m))
        XCTAssertFalse(PageZone.exceeds(PixelRect(x: 100 - m, y: 100, width: 100 + m, height: 100), zone: zone, margin: m))
        XCTAssertTrue(PageZone.exceeds(PixelRect(x: 100 - m - 1, y: 100, width: 100 + m + 1, height: 100), zone: zone, margin: m))
        XCTAssertFalse(PageZone.exceeds(PixelRect(x: 100, y: 100 - m, width: 100, height: 100 + m), zone: zone, margin: m))
        XCTAssertTrue(PageZone.exceeds(PixelRect(x: 100, y: 100 - m - 1, width: 100, height: 100 + m + 1), zone: zone, margin: m))
        XCTAssertFalse(PageZone.exceeds(PixelRect(x: 100, y: 100, width: 100 + m, height: 100), zone: zone, margin: m))
        XCTAssertTrue(PageZone.exceeds(PixelRect(x: 100, y: 100, width: 100 + m + 1, height: 100), zone: zone, margin: m))
        XCTAssertFalse(PageZone.exceeds(PixelRect(x: 100, y: 100, width: 100, height: 100 + m), zone: zone, margin: m))
        XCTAssertTrue(PageZone.exceeds(PixelRect(x: 100, y: 100, width: 100, height: 100 + m + 1), zone: zone, margin: m))
    }
}
