import AppKit
import ScreenCaptureKit
import ScreenshoterCore

/// Names shown to the user.
enum AppInfo {
    static let name = "Google Play Books Downloader"
    /// Binary, CLI link, log folder.
    static let cliName = "google-play-books-downloader"
}

/// Exit codes for the CLI path.
enum ExitCode {
    static let ok: Int32 = 0
    static let failure: Int32 = 1
    static let badArgs: Int32 = 2
    static let missingPermission: Int32 = 3
    static let pdfError: Int32 = 4
    static let windowNotFound: Int32 = 5
    /// Capture failed mid-run. A partial PDF is still written when pages exist.
    static let captureFailed: Int32 = 6

    /// Exit code for a finished run: `captureFailed` if the capture failed, else `ok`.
    static func `for`(_ reason: StopReason) -> Int32 {
        if case .captureFailed = reason { return captureFailed }
        return ok
    }
}

/// Logger, one ISO8601 timestamp per line, to stderr and to
/// `~/Library/Logs/google-play-books-downloader/google-play-books-downloader.log`. Over 5 MB the
/// file moves to `google-play-books-downloader.log.1`
/// (replacing the previous `.1`) and a new one starts.
enum Log {
    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let lock = NSLock()
    static let maxFileSize: UInt64 = 5 * 1024 * 1024

    static let fileURL: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/\(AppInfo.cliName)/\(AppInfo.cliName).log")
    private static var file: FileHandle?
    private static var fileFailed = false

    static func write(_ message: String) {
        lock.lock()
        defer { lock.unlock() }
        let data = Data("\(formatter.string(from: Date())) \(message)\n".utf8)
        FileHandle.standardError.write(data)
        appendToFile(data)
    }

    /// Caller holds `lock`. A log file that can't be opened is skipped for the rest of the run.
    private static func appendToFile(_ data: Data) {
        if file == nil && !fileFailed { file = openFile() }
        guard let handle = file else { return }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            if try handle.offset() > maxFileSize { rotate() }
        } catch {
            try? handle.close()
            file = nil
            fileFailed = true
        }
    }

    private static func openFile() -> FileHandle? {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !fm.fileExists(atPath: fileURL.path) { fm.createFile(atPath: fileURL.path, contents: nil) }
            return try FileHandle(forWritingTo: fileURL)
        } catch {
            fileFailed = true
            FileHandle.standardError.write(Data("cannot open log file \(fileURL.path): \(error)\n".utf8))
            return nil
        }
    }

    private static func rotate() {
        try? file?.close()
        file = nil
        let fm = FileManager.default
        let old = fileURL.appendingPathExtension("1")
        if fm.fileExists(atPath: old.path) { try? fm.removeItem(at: old) }
        try? fm.moveItem(at: fileURL, to: old)
    }
}

/// Monotonic clock for CaptureSession.
final class SystemClock: SessionClock {
    func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

    func sleep(_ seconds: Double) async throws {
        try await Task.sleep(for: .seconds(max(seconds, 0)))
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let options: CLIOptions
    private var session: CaptureSession?
    private var escMonitors: [Any] = []
    /// Exit code on terminate in `--autostart` mode (preview closed or Cmd+Q), set when the run ends.
    private var autostartExitCode = ExitCode.ok

    init(options: CLIOptions) {
        self.options = options
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.write("launch: \(Bundle.main.bundleURL.path) (\(Bundle.main.bundleIdentifier ?? "no bundle id")), args \(CommandLine.arguments.dropFirst().joined(separator: " "))")
        installMainMenu()
        if options.autostart {
            Task { @MainActor in await self.runHeadless() }
        } else {
            showSetup()
        }
    }

    // MARK: Headless (--autostart)

    @MainActor
    private func runHeadless() async {
        let title = options.windowTitle!   // main.swift exits with badArgs when it is missing
        var missing: [String] = []
        if !Permissions.screenRecording(request: true) { missing.append("Screen Recording") }
        if !Permissions.accessibility(prompt: true) { missing.append("Accessibility") }
        if !missing.isEmpty {
            Log.write("missing permission: \(missing.joined(separator: ", ")) — grant it in System Settings > Privacy & Security, then relaunch")
            exit(ExitCode.missingPermission)
        }

        let window: SCWindow
        do {
            guard let w = try await WindowPicker.find(titleContains: title) else {
                Log.write("no window matches \"\(title)\"")
                exit(ExitCode.windowNotFound)
            }
            window = w
        } catch {
            Log.write("cannot list windows: \(error)")
            exit(ExitCode.windowNotFound)
        }
        Log.write("window: \(window.owningApplication?.applicationName ?? "?") — \(window.title ?? "") \(window.frame)")

        var config = SessionConfig()
        config.splitSpreads = true   // Play Books two-page view: always split (covers stay whole in Core)
        if let n = options.maxPages { config.maxPages = n }
        if let l = options.latency { config.extraLatency = l }
        let key = options.key ?? Settings().nextKey
        let runName = options.runName ?? CachePaths.defaultRunName(date: Date())

        let started = Date()
        let outcome: (result: SessionResult, cacheDir: URL)
        do {
            outcome = try await runSession(window: window, config: config, key: key, runName: runName)
        } catch {
            Log.write("cannot start: \(error)")
            exit(ExitCode.failure)
        }
        let result = outcome.result
        Log.write("stopped: \(result.reason), \(result.pages.count) pages in \(outcome.cacheDir.path)")
        let code = ExitCode.for(result.reason)

        guard let pdfPath = options.savePDF else {
            autostartExitCode = code
            let model = makeMainWindow()
            model.headless = true
            model.showReview(result: result, cacheDir: outcome.cacheDir, duration: Date().timeIntervalSince(started))
            return
        }
        if code == ExitCode.captureFailed && result.pages.isEmpty {
            Log.write("capture failed with no pages, PDF skipped")
            exit(ExitCode.captureFailed)
        }
        let pdfURL = URL(fileURLWithPath: (pdfPath as NSString).expandingTildeInPath)
        do {
            try PDFExporter.export(imageURLs: result.pages, to: pdfURL, size: options.pdfSize)
        } catch {
            Log.write("PDF export failed: \(error)")
            exit(ExitCode.pdfError)
        }
        Log.write("PDF saved: \(pdfURL.path), \(result.pages.count) pages, size \(options.pdfSize.rawValue), reason \(result.reason)")
        exit(code)
    }

    // MARK: Session (shared with the GUI)

    /// Builds and runs one capture session on `window`. ESC (global + local) cancels it.
    /// `onPage` / `onStatus` / `onPagesReplaced` are called on the main thread. Throws only on setup errors
    /// (no owning app, cache dir not writable).
    @MainActor
    func runSession(window: SCWindow, config: SessionConfig, key: NextKey, runName: String,
                    onPage: ((Int, URL) -> Void)? = nil,
                    onStatus: ((String) -> Void)? = nil,
                    onPagesReplaced: (([URL]) -> Void)? = nil) async throws -> (result: SessionResult, cacheDir: URL) {
        guard let pid = window.owningApplication?.processID else { throw SetupError.noOwningApp }
        let dir = try CachePaths.uniqueRunDirectory(name: runName)
        let sink = try DiskPageSink(directory: dir, jpegQuality: config.jpegQuality)
        let scale = Self.backingScale(forCGFrame: window.frame)
        let capturer = SCKCapturer(window: window, scale: scale, config: config)
        Log.write("run dir \(dir.path), scale \(scale), full \(capturer.fullWidth)x\(capturer.fullHeight), preview \(capturer.previewWidth)x\(capturer.previewHeight), key \(key.rawValue)")

        let session = CaptureSession(config: config, capturer: capturer, turner: CGKeySender(pid: pid, key: key, windowTitle: window.title, windowFrame: window.frame),
                                     clock: SystemClock(), sink: sink, log: Log.write)
        // CaptureSession calls these off the main thread.
        if let onPage {
            session.onPageSaved = { n, url in DispatchQueue.main.async { onPage(n, url) } }
        }
        if let onStatus {
            session.onStatus = { text in DispatchQueue.main.async { onStatus(text) } }
        }
        if let onPagesReplaced {
            session.onPagesReplaced = { pages in DispatchQueue.main.async { onPagesReplaced(pages) } }
        }
        self.session = session
        installEscMonitors()
        let result = await session.run()
        removeEscMonitors()
        self.session = nil
        return (result, dir)
    }

    enum SetupError: Error { case noOwningApp }

    private func installEscMonitors() {
        let handler: (NSEvent) -> Bool = { [weak self] event in
            guard event.keyCode == 53, let session = self?.session else { return false }   // ESC
            Log.write("ESC pressed, stopping")
            session.cancel()
            return true
        }
        if let g = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { _ = handler($0) }) {
            escMonitors.append(g)
        }
        if let l = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { handler($0) ? nil : $0 }) {
            escMonitors.append(l)
        }
    }

    private func removeEscMonitors() {
        escMonitors.forEach { NSEvent.removeMonitor($0) }
        escMonitors = []
    }

    /// Backing scale of the screen holding most of `frame` (global CG coords, top-left origin).
    static func backingScale(forCGFrame frame: CGRect) -> CGFloat {
        var best: (area: CGFloat, scale: CGFloat)?
        for screen in NSScreen.screens {
            let inter = NSScreen.cgRect(fromAppKit: screen.frame).intersection(frame)
            guard !inter.isNull else { continue }
            let area = inter.width * inter.height
            if area > (best?.area ?? 0) { best = (area, screen.backingScaleFactor) }
        }
        return best?.scale ?? NSScreen.main?.backingScaleFactor ?? 2
    }

    // MARK: GUI (setup → capture HUD → review, one window)

    private var model: AppModel?
    private var mainWindow: MainWindowController?
    private var hud: CaptureHUDController?

    /// Creates the model and the main window once.
    @MainActor
    private func makeMainWindow() -> AppModel {
        if let model { return model }
        let model = AppModel()
        let controller = MainWindowController(model: model)
        // One window: closing it quits (in --autostart mode with the run's exit code).
        controller.onClose = { NSApp.terminate(nil) }
        model.onStart = { [weak self] window, config, key, runName in
            self?.startCapture(window: window, config: config, key: key, runName: runName)
        }
        model.onStop = { [weak self] in
            Log.write("Stop clicked, stopping")
            self?.session?.cancel()
        }
        self.model = model
        mainWindow = controller
        return model
    }

    @MainActor
    private func showSetup() {
        let model = makeMainWindow()
        mainWindow?.show()
        model.startPolling()
        // Launched from Finder / `open`, the first activate can land before the launch finishes
        // and the window stays behind the frontmost app. Ask once more on the next run-loop turn.
        DispatchQueue.main.async { [weak self] in
            guard model.stage == .setup else { return }
            self?.mainWindow?.show()
        }
    }

    /// Same `runSession` path as the CLI. Main window hidden and the HUD shown during the run,
    /// review after it.
    @MainActor
    private func startCapture(window: SCWindow, config: SessionConfig, key: NextKey, runName: String) {
        guard session == nil, let model else { return }
        Log.write("start: \(window.owningApplication?.applicationName ?? "?") — \(window.title ?? ""), run \(runName), key \(key.rawValue), latency \(config.extraLatency) s, split \(config.splitSpreads), maxPages \(config.maxPages)")
        model.beginCapture(target: window.frame)
        let hud = CaptureHUDController(model: model)
        hud.show(avoiding: window.frame)
        self.hud = hud
        let started = Date()
        Task { @MainActor in
            do {
                let outcome = try await self.runSession(
                    window: window, config: config, key: key, runName: runName,
                    onPage: { [weak model] n, url in model?.pageSaved(n, url) },
                    onStatus: { [weak model] text in model?.statusChanged(text) },
                    onPagesReplaced: { [weak model] pages in model?.pagesReplaced(pages) })
                Log.write("stopped: \(outcome.result.reason), \(outcome.result.pages.count) pages in \(outcome.cacheDir.path)")
                self.closeHUD()
                model.showReview(result: outcome.result, cacheDir: outcome.cacheDir,
                                 duration: Date().timeIntervalSince(started))
            } catch {
                Log.write("cannot start: \(error)")
                self.closeHUD()
                model.stage = .setup
                model.alert = AppModel.AlertItem(title: "Cannot start the capture", message: "\(error)")
            }
        }
    }

    @MainActor
    private func closeHUD() {
        hud?.close()
        hud = nil
    }

    /// Dock icon click with the window hidden (not during a run) brings it back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag, let model, model.stage != .capturing { mainWindow?.show() }
        return true
    }

    /// `--autostart` without `--save-pdf` exits with the run's code (6 if the capture failed).
    func applicationWillTerminate(_ notification: Notification) {
        if options.autostart { exit(autostartExitCode) }
    }

    // MARK: Menu (Quit + Edit, so Cmd+Q / Cmd+C / Cmd+V work in the fields)

    private func installMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit \(AppInfo.name)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)

        NSApp.mainMenu = main
    }
}
