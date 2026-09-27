import Foundation

/// Control-panel settings, persisted in `UserDefaults` under
/// `nextKey`, `extraLatency`, `maxPages`, `splitSpreads`.
public struct Settings: Equatable {
    public static let latencyRange: ClosedRange<Double> = 0...10
    public static let maxPagesRange: ClosedRange<Int> = 1...2000

    enum Key {
        static let nextKey = "nextKey"
        static let extraLatency = "extraLatency"
        static let maxPages = "maxPages"
        static let splitSpreads = "splitSpreads"
    }

    /// Google Play Books turns pages with Page Down (Right arrow does nothing there).
    public var nextKey: NextKey = .pageDown
    public var extraLatency: Double = SessionConfig().extraLatency
    public var maxPages: Int = SessionConfig().maxPages
    public var splitSpreads: Bool = SessionConfig().splitSpreads

    public init() {}

    /// Reads stored values. A missing, wrong-typed or out-of-range value falls back to the default.
    public init(defaults: UserDefaults) {
        if let raw = defaults.string(forKey: Key.nextKey), let k = NextKey(rawValue: raw) {
            nextKey = k
        }
        if let n = defaults.object(forKey: Key.extraLatency) as? NSNumber,
           Self.latencyRange.contains(n.doubleValue) {
            extraLatency = n.doubleValue
        }
        if let n = defaults.object(forKey: Key.maxPages) as? NSNumber,
           Self.maxPagesRange.contains(n.intValue), n.doubleValue == Double(n.intValue) {
            maxPages = n.intValue
        }
        if let n = defaults.object(forKey: Key.splitSpreads) as? NSNumber {
            splitSpreads = n.boolValue
        }
    }

    public func save(to defaults: UserDefaults) {
        defaults.set(nextKey.rawValue, forKey: Key.nextKey)
        defaults.set(extraLatency, forKey: Key.extraLatency)
        defaults.set(maxPages, forKey: Key.maxPages)
        defaults.set(splitSpreads, forKey: Key.splitSpreads)
    }

    /// Session config with these settings applied on top of the defaults.
    public var sessionConfig: SessionConfig {
        var c = SessionConfig()
        c.extraLatency = extraLatency
        c.maxPages = maxPages
        c.splitSpreads = splitSpreads
        return c
    }

    /// Seconds from a text field. nil if not a finite number or outside 0…10. Accepts "," as decimal mark.
    public static func parseLatency(_ text: String) -> Double? {
        let s = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        guard let d = Double(s), d.isFinite, latencyRange.contains(d) else { return nil }
        return d
    }

    /// Page cap from a text field. nil if not a whole number or outside 1…2000.
    public static func parseMaxPages(_ text: String) -> Int? {
        guard let n = Int(text.trimmingCharacters(in: .whitespaces)), maxPagesRange.contains(n) else { return nil }
        return n
    }

    /// Run length for the review header: "42 s", "1 min 12 s", "1 h 5 min". Negative → "0 s".
    public static func durationWords(_ seconds: Double) -> String {
        let t = max(Int(seconds.rounded()), 0)
        let h = t / 3600, m = (t % 3600) / 60, s = t % 60
        if h > 0 { return m > 0 ? "\(h) h \(m) min" : "\(h) h" }
        if m > 0 { return s > 0 ? "\(m) min \(s) s" : "\(m) min" }
        return "\(s) s"
    }

    /// Run name from the text field. Trims whitespace, replaces "/" and ":" (they would make
    /// nested or odd cache dirs) with "-". Empty, "." or ".." → `CachePaths.defaultRunName(date:)`.
    public static func runName(from text: String, date: Date) -> String {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        if s.isEmpty || s == "." || s == ".." { return CachePaths.defaultRunName(date: date) }
        return s
    }
}

extension StopReason {
    /// Short text for the preview header and the session's stop log line.
    public var words: String {
        switch self {
        case .endOfDocument: return "reached the end (page stopped changing)"
        case .capReached: return "hit the page cap"
        case .cancelled: return "stopped with ESC"
        case .captureFailed(let m): return "capture failed: \(m)"
        }
    }

    /// Preview header: "12 pages — reached the end (page stopped changing)".
    public func header(pageCount n: Int) -> String {
        "\(n) \(n == 1 ? "page" : "pages") — \(words)"
    }
}
