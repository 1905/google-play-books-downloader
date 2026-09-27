import XCTest
@testable import ScreenshoterCore

final class OptionsTests: XCTestCase {
    func testKeyCodes() {
        XCTAssertEqual(NextKey.space.keyCode, 49)
        XCTAssertEqual(NextKey.right.keyCode, 124)
        XCTAssertEqual(NextKey.down.keyCode, 125)
        XCTAssertEqual(NextKey.pageDown.keyCode, 121)
        XCTAssertEqual(NextKey.returnKey.keyCode, 36)
        XCTAssertEqual(NextKey.allCases.count, 5)
    }

    func testSessionConfigDefaults() {
        let c = SessionConfig()
        XCTAssertEqual(c.extraLatency, 0.5)
        XCTAssertEqual(c.maxPages, 500)
        XCTAssertTrue(c.splitSpreads)
        XCTAssertEqual(c.pollInterval, 0.15)
        XCTAssertEqual(c.changeTimeout, 10)
        XCTAssertEqual(c.settleTimeout, 15)
        XCTAssertEqual(c.matchDistance, 20)
        XCTAssertEqual(c.blankInkFraction, 0.02)
        XCTAssertEqual(c.blankInkBoxFraction, 0.06)
        XCTAssertEqual(c.blankWait, 6.0)
        XCTAssertEqual(c.stableDistance, 2)
        XCTAssertEqual(c.previewDownscale, 4)
        XCTAssertEqual(c.stablePolls, 2)
    }

    func testParseAllFlags() throws {
        let o = try CLIOptions.parse(["--window-title", "Chrome", "--autostart", "--max-pages", "12",
                                      "--key", "right", "--latency", "0.8", "--save-pdf", "/tmp/x.pdf",
                                      "--run-name", "t1", "--split", "--pdf-size", "small"])
        var want = CLIOptions()
        want.windowTitle = "Chrome"
        want.autostart = true
        want.maxPages = 12
        want.key = .right
        want.latency = 0.8
        want.savePDF = "/tmp/x.pdf"
        want.runName = "t1"
        want.split = true
        want.pdfSize = .small
        XCTAssertEqual(o, want)
    }

    func testParseEmpty() throws {
        XCTAssertEqual(try CLIOptions.parse([]), CLIOptions())
        XCTAssertEqual(CLIOptions().pdfSize, .balanced)
    }

    func testPDFSize() throws {
        for size in PDFSize.allCases {
            XCTAssertEqual(try CLIOptions.parse(["--pdf-size", size.rawValue]).pdfSize, size)
        }
        assertThrows(["--pdf-size", "huge"]) { $0 == .badValue("--pdf-size huge") }
        assertThrows(["--pdf-size"]) { $0 == .missingValue("--pdf-size") }
    }

    func assertThrows(_ args: [String], _ check: (CLIError) -> Bool,
                      file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try CLIOptions.parse(args), file: file, line: line) { err in
            guard let e = err as? CLIError, check(e) else {
                return XCTFail("unexpected error \(err)", file: file, line: line)
            }
        }
    }

    func testBadKey() {
        assertThrows(["--key", "nope"]) { if case .badValue = $0 { return true }; return false }
    }

    func testMissingValue() {
        assertThrows(["--max-pages"]) { $0 == .missingValue("--max-pages") }
        assertThrows(["--max-pages", "--autostart"]) { $0 == .missingValue("--max-pages") }
    }

    func testUnknownFlag() {
        assertThrows(["--foo"]) { $0 == .unknownFlag("--foo") }
    }

    func testMaxPagesZero() {
        assertThrows(["--max-pages", "0"]) { if case .badValue = $0 { return true }; return false }
        assertThrows(["--max-pages", "abc"]) { if case .badValue = $0 { return true }; return false }
    }

    func testLatencyRange() throws {
        XCTAssertEqual(try CLIOptions.parse(["--latency", "0"]).latency, 0)
        XCTAssertEqual(try CLIOptions.parse(["--latency", "10"]).latency, 10)
        assertThrows(["--latency", "10.5"]) { if case .badValue = $0 { return true }; return false }
        assertThrows(["--latency", "-1"]) { if case .badValue = $0 { return true }; return false }
    }
}
