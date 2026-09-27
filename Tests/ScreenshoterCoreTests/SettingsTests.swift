import XCTest
@testable import ScreenshoterCore

final class SettingsTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() {
        suite = "SettingsTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    func testDefaultsMatchSpec() {
        let s = Settings(defaults: defaults)
        XCTAssertEqual(s, Settings())
        XCTAssertEqual(s.nextKey, .pageDown)
        XCTAssertEqual(s.extraLatency, 0.5)
        XCTAssertEqual(s.maxPages, 500)
        XCTAssertTrue(s.splitSpreads)
    }

    func testRoundTrip() {
        var s = Settings()
        s.nextKey = .space
        s.extraLatency = 1.25
        s.maxPages = 42
        s.splitSpreads = false
        s.save(to: defaults)
        XCTAssertEqual(Settings(defaults: defaults), s)
        XCTAssertEqual(defaults.string(forKey: "nextKey"), "space")
        XCTAssertEqual(defaults.double(forKey: "extraLatency"), 1.25)
        XCTAssertEqual(defaults.integer(forKey: "maxPages"), 42)
        XCTAssertEqual(defaults.object(forKey: "splitSpreads") as? Bool, false)
    }

    func testBadStoredValuesFallBack() {
        defaults.set("tab", forKey: "nextKey")
        defaults.set(99.0, forKey: "extraLatency")
        defaults.set(0, forKey: "maxPages")
        defaults.set("yes", forKey: "splitSpreads")
        XCTAssertEqual(Settings(defaults: defaults), Settings())

        defaults.set(-1.0, forKey: "extraLatency")
        defaults.set(2001, forKey: "maxPages")
        XCTAssertEqual(Settings(defaults: defaults), Settings())

        defaults.set(12.5, forKey: "maxPages")
        XCTAssertEqual(Settings(defaults: defaults).maxPages, 500)
    }

    func testSessionConfig() {
        var s = Settings()
        s.extraLatency = 2
        s.maxPages = 12
        s.splitSpreads = false
        let c = s.sessionConfig
        XCTAssertEqual(c.extraLatency, 2)
        XCTAssertEqual(c.maxPages, 12)
        XCTAssertFalse(c.splitSpreads)
        var expected = SessionConfig()
        expected.extraLatency = 2
        expected.maxPages = 12
        expected.splitSpreads = false
        XCTAssertEqual(c, expected)
    }

    func testParseLatency() {
        XCTAssertEqual(Settings.parseLatency("0"), 0)
        XCTAssertEqual(Settings.parseLatency("10"), 10)
        XCTAssertEqual(Settings.parseLatency(" 0.8 "), 0.8)
        XCTAssertEqual(Settings.parseLatency("0,8"), 0.8)
        XCTAssertNil(Settings.parseLatency("10.01"))
        XCTAssertNil(Settings.parseLatency("-0.1"))
        XCTAssertNil(Settings.parseLatency(""))
        XCTAssertNil(Settings.parseLatency("abc"))
        XCTAssertNil(Settings.parseLatency("nan"))
        XCTAssertNil(Settings.parseLatency("inf"))
    }

    func testParseMaxPages() {
        XCTAssertEqual(Settings.parseMaxPages("1"), 1)
        XCTAssertEqual(Settings.parseMaxPages("2000"), 2000)
        XCTAssertEqual(Settings.parseMaxPages(" 12 "), 12)
        XCTAssertNil(Settings.parseMaxPages("0"))
        XCTAssertNil(Settings.parseMaxPages("2001"))
        XCTAssertNil(Settings.parseMaxPages("1.5"))
        XCTAssertNil(Settings.parseMaxPages(""))
        XCTAssertNil(Settings.parseMaxPages("x"))
    }

    func testRunName() {
        let date = Date(timeIntervalSince1970: 0)
        let def = CachePaths.defaultRunName(date: date)
        XCTAssertEqual(Settings.runName(from: "", date: date), def)
        XCTAssertEqual(Settings.runName(from: "   ", date: date), def)
        XCTAssertEqual(Settings.runName(from: ".", date: date), def)
        XCTAssertEqual(Settings.runName(from: "..", date: date), def)
        XCTAssertEqual(Settings.runName(from: " Action Comics 1 ", date: date), "Action Comics 1")
        XCTAssertEqual(Settings.runName(from: "a/b:c", date: date), "a-b-c")
    }

    func testStopReasonHeader() {
        XCTAssertEqual(StopReason.endOfDocument.header(pageCount: 12), "12 pages — reached the end (page stopped changing)")
        XCTAssertEqual(StopReason.capReached.header(pageCount: 1), "1 page — hit the page cap")
        XCTAssertEqual(StopReason.cancelled.header(pageCount: 0), "0 pages — stopped with ESC")
        XCTAssertEqual(StopReason.captureFailed("window gone").header(pageCount: 3), "3 pages — capture failed: window gone")
    }

    func testDurationWords() {
        XCTAssertEqual(Settings.durationWords(0), "0 s")
        XCTAssertEqual(Settings.durationWords(-3), "0 s")
        XCTAssertEqual(Settings.durationWords(41.6), "42 s")
        XCTAssertEqual(Settings.durationWords(60), "1 min")
        XCTAssertEqual(Settings.durationWords(72), "1 min 12 s")
        XCTAssertEqual(Settings.durationWords(3600), "1 h")
        XCTAssertEqual(Settings.durationWords(3900), "1 h 5 min")
    }
}
