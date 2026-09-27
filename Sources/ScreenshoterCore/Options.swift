import Foundation

/// Key sent to the viewer to turn the page.
public enum NextKey: String, CaseIterable {
    case space, right, down, pageDown, returnKey

    /// macOS virtual key code (kVK_*).
    public var keyCode: UInt16 {
        switch self {
        case .space: return 49
        case .right: return 124
        case .down: return 125
        case .pageDown: return 121
        case .returnKey: return 36
        }
    }
}

/// Tunables for one capture run. Times are seconds.
public struct SessionConfig: Equatable {
    public var extraLatency: Double = 0.5
    public var maxPages: Int = 500
    /// Split 2-up spreads into two pages. The first shot (front cover) is never split, and a
    /// split last shot (back cover) is merged back at the end of the document.
    public var splitSpreads = true
    public var pollInterval: Double = 0.15
    public var changeTimeout: Double = 10
    public var settleTimeout: Double = 15
    public var matchDistance = 20
    public var stableDistance = 2
    public var previewDownscale = 4
    public var stablePolls = 2
    /// Near-blank page (see `GrayImage.isNearBlank`): ink below this share of the page, or
    /// all ink inside a box below `blankInkBoxFraction` of the page. Near-blank pages get the
    /// placeholder wait and are exempt from the wrap check.
    public var blankInkFraction: Double = 0.02
    public var blankInkBoxFraction: Double = 0.06
    /// A near-blank shot may be a loading placeholder: poll this long for real content first.
    public var blankWait: Double = 6.0
    /// JPEG quality (0…1) of saved pages. The PDF embeds these bytes as-is.
    public var jpegQuality: Double = 0.85

    public init() {}

    /// Preview size for a full shot: integer division by `previewDownscale` (≥ 1), at least 1×1.
    /// SCKCapturer and CaptureSession both use it, so the preview lands on the size the session expects.
    public func previewSize(fullWidth: Int, fullHeight: Int) -> (width: Int, height: Int) {
        let d = max(previewDownscale, 1)
        return (max(fullWidth / d, 1), max(fullHeight / d, 1))
    }
}

public enum CLIError: Error, Equatable {
    case unknownFlag(String), missingValue(String), badValue(String)
}

/// Command-line flags for headless / automated runs.
public struct CLIOptions: Equatable {
    public var windowTitle: String?
    public var runName: String?
    public var autostart = false
    public var maxPages: Int?
    public var key: NextKey?
    public var latency: Double?
    public var savePDF: String?
    /// Size preset for `--save-pdf`.
    public var pdfSize: PDFSize = .balanced
    public var split = false

    public init() {}

    /// Parses `args` (without argv[0]).
    public static func parse(_ args: [String]) throws -> CLIOptions {
        var o = CLIOptions()
        var i = 0
        func value(_ flag: String) throws -> String {
            i += 1
            guard i < args.count, !args[i].hasPrefix("--") else { throw CLIError.missingValue(flag) }
            return args[i]
        }
        while i < args.count {
            let flag = args[i]
            switch flag {
            case "--window-title": o.windowTitle = try value(flag)
            case "--run-name": o.runName = try value(flag)
            case "--save-pdf": o.savePDF = try value(flag)
            case "--pdf-size":
                let v = try value(flag)
                guard let size = PDFSize(rawValue: v) else { throw CLIError.badValue("\(flag) \(v)") }
                o.pdfSize = size
            case "--autostart": o.autostart = true
            case "--split": o.split = true
            case "--max-pages":
                let v = try value(flag)
                guard let n = Int(v), n >= 1 else { throw CLIError.badValue("\(flag) \(v)") }
                o.maxPages = n
            case "--key":
                let v = try value(flag)
                guard let k = NextKey(rawValue: v) else { throw CLIError.badValue("\(flag) \(v)") }
                o.key = k
            case "--latency":
                let v = try value(flag)
                guard let d = Double(v), Settings.latencyRange.contains(d) else { throw CLIError.badValue("\(flag) \(v)") }
                o.latency = d
            default:
                throw CLIError.unknownFlag(flag)
            }
            i += 1
        }
        return o
    }
}
