import AppKit
import ScreenshoterCore

let usage = """
usage: google-play-books-downloader [--window-title <substring>] [--run-name <name>] [--autostart]
                                    [--max-pages N] [--key space|right|down|pageDown|returnKey]
                                    [--latency 0-10] [--split] [--save-pdf <path>]
                                    [--pdf-size full|balanced|small]

  --window-title  pick the first window whose title (or app name) contains this
  --run-name      cache folder name under ~/Library/Caches/google-play-books-downloader (default: date)
  --autostart     start capturing without the GUI (needs --window-title)
  --max-pages     page cap (default 500)
  --key           next-page key (default pageDown)
  --latency       extra wait after a page change, seconds (default 0.5)
  --split         no-op, kept for old scripts: spreads are always split
  --save-pdf      write the PDF here and exit instead of showing the preview
  --pdf-size      PDF size for --save-pdf (default balanced): full = cached pages as-is,
                  balanced = pages ≤1600 px tall at JPEG 0.75, small = ≤1200 px at 0.65

exit codes: 0 ok, 1 setup error, 2 bad arguments, 3 missing permission,
            4 PDF error, 5 window not found, 6 capture failed
"""

let args = Array(CommandLine.arguments.dropFirst())
if args.contains("--help") || args.contains("-h") {
    print(usage)
    exit(ExitCode.ok)
}

let options: CLIOptions
do {
    options = try CLIOptions.parse(args)
} catch {
    let msg: String
    switch error as? CLIError {
    case .unknownFlag(let f)?: msg = "unknown flag \(f)"
    case .missingValue(let f)?: msg = "missing value for \(f)"
    case .badValue(let v)?: msg = "bad value: \(v)"
    case nil: msg = "\(error)"
    }
    FileHandle.standardError.write(Data("error: \(msg)\n\n\(usage)\n".utf8))
    exit(ExitCode.badArgs)
}
if options.autostart && options.windowTitle == nil {
    FileHandle.standardError.write(Data("error: --autostart needs --window-title\n\n\(usage)\n".utf8))
    exit(ExitCode.badArgs)
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate(options: options)
app.delegate = delegate
app.run()
