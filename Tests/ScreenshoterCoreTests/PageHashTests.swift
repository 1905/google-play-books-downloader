import XCTest
@testable import ScreenshoterCore

final class PageHashTests: XCTestCase {
    func testHasFourWords() {
        XCTAssertEqual(PageHash(TestImages.noisePage(400, 600, seed: 1)).words.count, 4)
    }

    func testSameImageDistanceZero() {
        let img = TestImages.noisePage(400, 600, seed: 1)
        XCTAssertEqual(PageHash(img).distance(to: PageHash(img)), 0)
    }

    func testOnePixelChangeIsSmall() {
        let a = TestImages.noisePage(400, 600, seed: 7)
        var b = a
        b[200, 300] = b[200, 300] == 0 ? 255 : 0
        XCTAssertLessThanOrEqual(PageHash(a).distance(to: PageHash(b)), 2)
    }

    func testDifferentPagesAreFar() {
        let pairs: [(UInt64, UInt64)] = [(1, 2), (3, 4), (10, 11), (42, 43), (100, 999)]
        for (s1, s2) in pairs {
            let d = PageHash(TestImages.noisePage(400, 600, seed: s1))
                .distance(to: PageHash(TestImages.noisePage(400, 600, seed: s2)))
            XCTAssertGreaterThan(d, 6, "seeds \(s1)/\(s2)")
        }
    }

    func testSolidWhiteVsSolidWhite() {
        let a = TestImages.solid(400, 600, 255), b = TestImages.solid(200, 300, 255)
        XCTAssertEqual(PageHash(a).distance(to: PageHash(b)), 0)
    }
}
