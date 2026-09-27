import CoreGraphics
import XCTest
@testable import ScreenshoterCore

final class GrayImageTests: XCTestCase {
    func testCropReturnsRightPixels() {
        let img = GrayImage(width: 4, height: 3, pixels: Array(0..<12).map(UInt8.init))
        let c = img.cropped(PixelRect(x: 1, y: 1, width: 2, height: 2))
        XCTAssertEqual(c.width, 2)
        XCTAssertEqual(c.height, 2)
        XCTAssertEqual(c.pixels, [5, 6, 9, 10])
    }

    func testResizeAveragesArea() {
        let img = GrayImage(width: 4, height: 4, pixels: [
            0, 4, 100, 100,
            8, 12, 100, 100,
            200, 200, 10, 20,
            200, 200, 30, 40,
        ])
        let r = img.resized(width: 2, height: 2)
        XCTAssertEqual(r.width, 2)
        XCTAssertEqual(r.height, 2)
        XCTAssertEqual(r.pixels, [6, 100, 200, 25])
    }

    func testMeanAndStdOnSolid() {
        let img = TestImages.solid(10, 10, 77)
        let (mean, std) = img.meanAndStd(PixelRect(x: 2, y: 2, width: 5, height: 5))
        XCTAssertEqual(mean, 77, accuracy: 1e-9)
        XCTAssertEqual(std, 0, accuracy: 1e-9)
    }

    func testMeanAndStdOnTwoValues() {
        let img = GrayImage(width: 2, height: 1, pixels: [0, 100])
        let (mean, std) = img.meanAndStd(PixelRect(x: 0, y: 0, width: 2, height: 1))
        XCTAssertEqual(mean, 50, accuracy: 1e-9)
        XCTAssertEqual(std, 50, accuracy: 1e-9)
    }

    func testSubscriptReadWrite() {
        var img = TestImages.solid(3, 2, 0)
        img[2, 1] = 9
        XCTAssertEqual(img[2, 1], 9)
        XCTAssertEqual(img.pixels[5], 9)
    }

    func testInitFromRGBCGImageWithDownscale() throws {
        let cg = TestImages.rgbCGImage(100, 60, fill: (r: 90, g: 90, b: 90))
        let img = try XCTUnwrap(GrayImage(cgImage: cg, downscale: 2))
        XCTAssertEqual(img.width, 50)
        XCTAssertEqual(img.height, 30)
        for p in img.pixels {
            XCTAssertLessThanOrEqual(abs(Int(p) - 90), 1)
        }
    }

    func testInitFromGrayCGImageKeepsTopLeftOrigin() throws {
        var src = TestImages.solid(8, 6, 0)
        TestImages.drawRect(into: &src, rect: PixelRect(x: 0, y: 0, width: 2, height: 1), value: 255)
        let img = try XCTUnwrap(GrayImage(cgImage: TestImages.cgImage(from: src)))
        XCTAssertEqual(img, src)
    }

    func testPixelRectScaledAndDerived() {
        let r = PixelRect(x: 1, y: 2, width: 3, height: 4)
        XCTAssertEqual(r.scaled(by: 4), PixelRect(x: 4, y: 8, width: 12, height: 16))
        XCTAssertEqual(r.maxX, 4)
        XCTAssertEqual(r.maxY, 6)
        XCTAssertEqual(r.area, 12)
        XCTAssertEqual(r.cgRect, CGRect(x: 1, y: 2, width: 3, height: 4))
    }

    func testPixelRectClamped() {
        XCTAssertEqual(PixelRect(x: -5, y: -2, width: 20, height: 10).clamped(width: 10, height: 6),
                       PixelRect(x: 0, y: 0, width: 10, height: 6))
        XCTAssertEqual(PixelRect(x: 8, y: 4, width: 10, height: 10).clamped(width: 10, height: 6),
                       PixelRect(x: 8, y: 4, width: 2, height: 2))
        XCTAssertEqual(PixelRect(x: 20, y: 1, width: 5, height: 1).clamped(width: 10, height: 6).area, 0)
    }

    // MARK: isNearBlank

    func nearBlank(_ g: GrayImage) -> Bool {
        let c = SessionConfig()
        return g.isNearBlank(g.bounds, inkFraction: c.blankInkFraction, inkBoxFraction: c.blankInkBoxFraction)
    }

    func testLoadingPlaceholderWithEdgeShadingAndSpinnerIsNearBlank() {
        // Real archive.org loading page: cream, darker edge shading on the left, spinner in the middle.
        var g = TestImages.solid(620, 912, 250)
        TestImages.drawRect(into: &g, rect: PixelRect(x: 0, y: 0, width: 3, height: 912), value: 225)
        for y in 0..<24 {  // ring-like spinner: dark and grey dashes
            for x in 0..<24 where (x + y) % 3 != 0 { g[298 + x, 444 + y] = (x / 6) % 2 == 0 ? 60 : 150 }
        }
        XCTAssertTrue(nearBlank(g))
    }

    func testLoadingSpreadWithGutterShadingIsNearBlank() {
        // The session tests the whole spread before the split: the gutter shading sits in the
        // middle, not in the margin. It passes on the ink share (< 2%), not the ink box.
        var g = TestImages.solid(1240, 912, 250)
        TestImages.drawRect(into: &g, rect: PixelRect(x: 614, y: 0, width: 12, height: 912), value: 215)
        TestImages.drawRect(into: &g, rect: PixelRect(x: 298, y: 444, width: 24, height: 24), value: 80)
        TestImages.drawRect(into: &g, rect: PixelRect(x: 918, y: 444, width: 24, height: 24), value: 80)
        XCTAssertTrue(nearBlank(g))
    }

    func testSparseTextPageIsNotNearBlank() {
        var g = TestImages.solid(620, 912, 250)
        for i in 0..<10 {  // 10 short lines top to bottom, ~5% ink
            TestImages.drawRect(into: &g, rect: PixelRect(x: 60 + (i % 3) * 40, y: 60 + i * 82, width: 300, height: 10), value: 30)
        }
        XCTAssertFalse(nearBlank(g))
    }

    func testBlankPageWithPageNumberIsNearBlank() {
        var g = TestImages.solid(620, 912, 245)
        TestImages.drawRect(into: &g, rect: PixelRect(x: 300, y: 850, width: 20, height: 14), value: 20)
        XCTAssertTrue(nearBlank(g))
    }

    func testNoisePageIsNotNearBlank() {
        XCTAssertFalse(nearBlank(TestImages.noisePage(300, 400, seed: 3)))
    }

    func testEmptyRectIsNearBlank() {
        XCTAssertTrue(TestImages.solid(10, 10, 0).isNearBlank(PixelRect(x: 0, y: 0, width: 0, height: 0),
                                                              inkFraction: 0.02, inkBoxFraction: 0.06))
    }
}
