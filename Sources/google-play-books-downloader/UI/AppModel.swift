import AppKit
import Observation
import ScreenCaptureKit
import ScreenshoterCore

/// Screen Recording state. The grant only takes effect after a relaunch.
enum ScreenPermission: Equatable { case granted, needed, needsRelaunch }

struct PermissionState: Equatable {
    var screen: ScreenPermission = .needed
    var accessibility = false
    var allGranted: Bool { screen == .granted && accessibility }
}

/// The picked viewer window, as the setup screen shows it.
struct SourceWindow {
    var window: SCWindow
    var id: CGWindowID { window.windowID }
    var appName: String
    var title: String
    var pid: pid_t
    var appIcon: NSImage?
    /// Global CG points (top-left origin), refreshed while the setup screen is visible.
    var frame: CGRect
    /// Browser tab title contains "Google Play Books".
    var isPlayBooks: Bool { title.localizedCaseInsensitiveContains("Google Play Books") }

    init(_ window: SCWindow) {
        self.window = window
        let app = window.owningApplication
        appName = app?.applicationName ?? "Unknown app"
        title = window.title ?? ""
        pid = app?.processID ?? 0
        appIcon = app.flatMap { NSRunningApplication(processIdentifier: $0.processID)?.icon }
        frame = window.frame
    }
}

enum SourceHealth: Equatable { case ok, offScreen, gone }

/// Live numbers for the capture HUD.
struct CaptureProgress {
    var pageCount = 0
    var lastPage: URL?
    var status = "Starting…"
    var startedAt = Date()
    /// Target window frame in global CG points, for HUD placement.
    var targetFrame: CGRect = .zero
}

/// Review of one finished run.
struct ReviewState {
    var pages: [URL]
    /// 1-based capture number per page, stable while pages are removed.
    let captureNumbers: [URL: Int]
    let reason: StopReason
    let cacheDir: URL
    let duration: TimeInterval
    var selection: Set<URL> = []
    /// Last plainly clicked page, the anchor for ⇧-click ranges.
    var anchor: URL?
    var saving = false
    var savedPDF: URL?
    var savedCount = 0
    /// Real size of the saved PDF, for the banner. nil if it could not be read.
    var savedBytes: Int64?
    var cacheTrashed = false
    /// Pages much shorter than the run's median page (see `PageCheck`), filled in after the run.
    var incomplete: Set<URL> = []

    init(pages: [URL], reason: StopReason, cacheDir: URL, duration: TimeInterval) {
        self.pages = pages
        var n: [URL: Int] = [:]
        for (i, u) in pages.enumerated() { n[u] = i + 1 }
        captureNumbers = n
        self.reason = reason
        self.cacheDir = cacheDir
        self.duration = duration
    }

    var runName: String { cacheDir.lastPathComponent }
    var locked: Bool { saving || cacheTrashed }
}

@Observable @MainActor
final class AppModel {
    enum Stage { case setup, capturing, review }

    var stage: Stage = .setup {
        didSet {
            guard stage != oldValue else { return }
            onStageChange?(stage)
            if stage == .setup { startPolling() } else { stopPolling() }
        }
    }

    var settings = Settings(defaults: .standard) {
        didSet {
            guard settings != oldValue else { return }
            settings.save(to: .standard)
            Log.write("settings saved: \(Self.describe(settings))")
        }
    }
    /// Run-name field text. Empty → date-time name.
    var runNameText = ""

    // MARK: Permissions

    var permissions = PermissionState()
    /// The user clicked "Allow…" for Screen Recording in this session.
    var screenRequested = false
    /// The permissions card is expanded although everything is granted.
    var permissionsExpanded = false
    /// No app bundle: macOS ties the grants to the terminal app that started the binary.
    let runningFromTerminal = Bundle.main.bundleIdentifier == nil

    // MARK: Source window

    var source: SourceWindow?
    var sourceThumbnail: CGImage?
    var sourceHealth: SourceHealth = .ok
    var windowList: [SourceWindow] = []
    var windowListError: String?
    var testKeyMessage: String?

    // MARK: Capture / review

    var progress = CaptureProgress()
    var lastPageThumb: NSImage?
    var review: ReviewState?
    var alert: AlertItem?
    /// `--autostart` review: no "New capture" (closing the window quits with the run's exit code).
    var headless = false

    struct AlertItem: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    // MARK: Hooks set by AppDelegate / MainWindowController

    var onStageChange: ((Stage) -> Void)?
    /// Starts a run on the window (already re-fetched by the caller).
    var onStart: ((SCWindow, SessionConfig, NextKey, String) -> Void)?
    var onStop: (() -> Void)?
    /// Main window, for sheets and hiding it during the click picker.
    weak var window: NSWindow?

    @ObservationIgnored private var pollTask: Task<Void, Never>?

    init() {
        refreshPermissions()
    }

    // MARK: Polling (setup stage)

    /// Every 1 s: permissions while one is missing. Every 2 s: source window state + thumbnail.
    func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                guard let self else { return }
                if !self.permissions.allGranted || tick == 0 { self.refreshPermissions() }
                if tick % 2 == 0 { await self.refreshSource() }
                tick += 1
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    func refreshPermissions() {
        var p = PermissionState()
        // Preflight only: nothing here may call anything that can show the system prompt.
        if Permissions.screenRecording(request: false) {
            p.screen = .granted
        } else {
            // A grant only shows up in preflight after a relaunch, so after "Allow…" we ask for one.
            p.screen = screenRequested ? .needsRelaunch : .needed
        }
        p.accessibility = Permissions.accessibility(prompt: false)
        if p != permissions {
            let wasAll = permissions.allGranted
            permissions = p
            if p.allGranted && !wasAll { permissionsExpanded = false }
        }
    }

    // MARK: Permission actions

    func requestScreenRecording() {
        screenRequested = true
        _ = Permissions.screenRecording(request: true)
        // On macOS 26 CGRequestScreenCaptureAccess alone may not add the app to the Screen
        // Recording list; a real ScreenCaptureKit call registers it and shows the system prompt.
        Task { _ = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true) }
        refreshPermissions()
    }

    func requestAccessibility() {
        _ = Permissions.accessibility(prompt: true)
        refreshPermissions()
    }

    enum SettingsPane: String {
        case screenRecording = "Privacy_ScreenCapture"
        case accessibility = "Privacy_Accessibility"
    }

    func openSettings(_ pane: SettingsPane) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane.rawValue)") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Starts a fresh instance of this app bundle, then quits this one.
    func relaunch() {
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { _, error in
            let message = error?.localizedDescription
            Task { @MainActor [weak self] in
                if let message {
                    self?.alert = AlertItem(title: "Cannot relaunch", message: "\(message)\n\nQuit \(AppInfo.name) and open it again.")
                } else {
                    NSApp.terminate(nil)
                }
            }
        }
    }

    // MARK: Source

    /// Hides the main window, shows the click overlay, then comes back.
    func pickByClick() {
        guard permissions.screen == .granted else { return }   // the picker uses ScreenCaptureKit
        window?.orderOut(nil)
        WindowPicker.pick { [weak self] picked in
            guard let self else { return }
            if let picked { self.setSource(picked) }
            self.window?.makeKeyAndOrderFront(nil)
            NSApp.activate()
        }
    }

    func loadWindowList() async {
        guard permissions.screen == .granted else {   // SCShareableContent can show the prompt
            windowList = []
            windowListError = "Allow Screen Recording to list windows."
            return
        }
        do {
            let all = try await WindowPicker.listWindows().map(SourceWindow.init)
            // Play Books windows first, each group front to back.
            windowList = all.filter(\.isPlayBooks) + all.filter { !$0.isPlayBooks }
            windowListError = nil
        } catch {
            windowList = []
            windowListError = "Cannot list windows: \(error.localizedDescription)"
        }
    }

    func pick(from candidate: SourceWindow) {
        setSource(candidate.window)
    }

    func setSource(_ w: SCWindow) {
        source = SourceWindow(w)
        sourceHealth = .ok
        sourceThumbnail = nil
        testKeyMessage = nil
        Task { await refreshSource() }
    }

    /// Updates the source's health, frame and thumbnail. Does nothing without Screen Recording,
    /// so the 2-s poll never touches the window list or ScreenCaptureKit (both can prompt).
    func refreshSource() async {
        guard permissions.screen == .granted, let current = source else { return }
        switch WindowPicker.state(of: current.id) {
        case .gone:
            sourceHealth = .gone
            return
        case .offScreen:
            sourceHealth = .offScreen
            return
        case .onScreen(let frame):
            sourceHealth = .ok
            if source?.id == current.id { source?.frame = frame }
        }
        guard let fresh = try? await WindowPicker.window(id: current.id),
              let image = try? await SCKCapturer.snapshot(window: fresh, maxWidth: 640),
              source?.id == current.id else { return }
        source?.window = fresh
        source?.title = fresh.title ?? source?.title ?? ""
        sourceThumbnail = image
    }

    /// Raises the source window (Accessibility raise + app activation).
    func showSource() {
        guard let s = source else { return }
        do {
            try CGKeySender(pid: s.pid, key: settings.nextKey, windowTitle: s.title, windowFrame: s.frame).bringToFront()
        } catch {
            alert = AlertItem(title: "Cannot show the window", message: "\(error)")
        }
    }

    /// Sends the next-page key once to the source window, then brings the setup window back up.
    func testKey() {
        guard let s = source else { return }
        let sender = CGKeySender(pid: s.pid, key: settings.nextKey, windowTitle: s.title, windowFrame: s.frame)
        let keyName = settings.nextKey.displayName
        Task { @MainActor in
            do {
                try sender.bringToFront()
                try await Task.sleep(for: .milliseconds(300))   // let the activation land
                try sender.turnPage()
                testKeyMessage = "Sent \(keyName). Did the page turn?"
            } catch {
                testKeyMessage = "Could not send the key: \(error)"
            }
            try? await Task.sleep(for: .seconds(1.2))
            if stage == .setup { window?.orderFrontRegardless() }
        }
    }

    // MARK: Start

    /// Why Start is disabled, nil when it's enabled.
    var startBlocker: String? {
        switch permissions.screen {
        case .needed: return "Allow Screen Recording first."
        case .needsRelaunch: return "Relaunch the app to use Screen Recording."
        case .granted: break
        }
        if !permissions.accessibility { return "Allow Accessibility first." }
        guard source != nil else { return "Choose the Google Play Books window first." }
        switch sourceHealth {
        case .gone: return "The window was closed. Choose it again."
        case .offScreen: return "The window is minimized or on another Space. Show it first."
        case .ok: return nil
        }
    }

    func start() {
        // End editing first, so a name still in the field editor lands in `runNameText`.
        window?.makeFirstResponder(nil)
        guard startBlocker == nil, let s = source else { return }
        let runName = Settings.runName(from: runNameText, date: Date())
        var current = settings
        current.splitSpreads = true   // Play Books two-page view; no UI switch any more
        current.save(to: .standard)   // what runs is what's stored
        let config = current.sessionConfig
        let key = current.nextKey
        Log.write("start requested: window \"\(s.title)\" (\(s.appName)), run name \"\(runName)\" (field \"\(runNameText)\"), \(Self.describe(current))")
        Task { @MainActor in
            // The SCWindow frame is a snapshot and the window may have moved: re-fetch it.
            guard let fresh = try? await WindowPicker.window(id: s.id) else {
                sourceHealth = .gone
                return
            }
            onStart?(fresh, config, key, runName)
        }
    }

    static func describe(_ s: Settings) -> String {
        "key \(s.nextKey.rawValue), latency \(s.extraLatency) s, split \(s.splitSpreads), maxPages \(s.maxPages)"
    }

    // MARK: Capture progress

    func beginCapture(target: CGRect) {
        progress = CaptureProgress(targetFrame: target)
        lastPageThumb = nil
        stage = .capturing
    }

    func pageSaved(_ count: Int, _ url: URL) {
        progress.pageCount = count
        progress.lastPage = url
        Task {
            if let img = await Thumbnails.image(for: url, maxPixel: 240), progress.lastPage == url {
                lastPageThumb = img
            }
        }
    }

    /// Core merged the back cover's two halves into one file at the end of the run.
    /// Only the HUD needs it: `SessionResult.pages` (what Review shows) is already the merged list,
    /// and this call can arrive after Review opened.
    func pagesReplaced(_ pages: [URL]) {
        guard stage == .capturing else { return }
        progress.pageCount = pages.count
        if let last = pages.last { pageSaved(pages.count, last) }
    }

    func statusChanged(_ text: String) {
        progress.status = text
    }

    func stop() {
        progress.status = "Stopping…"
        onStop?()
    }

    // MARK: Review

    func showReview(result: SessionResult, cacheDir: URL, duration: TimeInterval) {
        review = ReviewState(pages: result.pages, reason: result.reason, cacheDir: cacheDir, duration: duration)
        stage = .review
        let pages = result.pages
        Task {
            let flagged = await Task.detached(priority: .userInitiated) { PageCheck.incompletePages(pages) }.value
            if review?.cacheDir == cacheDir { review?.incomplete = flagged }
        }
    }

    /// Current pages that look cut off.
    var incompletePages: [URL] {
        guard let r = review else { return [] }
        return r.pages.filter { r.incomplete.contains($0) }
    }

    func selectIncomplete() {
        let pages = incompletePages
        guard !pages.isEmpty else { return }
        review?.selection = Set(pages)
        review?.anchor = pages.first
    }

    /// Click on a page. ⌘ toggles, ⇧ extends from the anchor, plain click selects only it.
    func click(_ url: URL, command: Bool, shift: Bool) {
        guard var r = review else { return }
        if shift, let anchor = r.anchor, let a = r.pages.firstIndex(of: anchor), let b = r.pages.firstIndex(of: url) {
            let range = r.pages[min(a, b)...max(a, b)]
            if command { r.selection.formUnion(range) } else { r.selection = Set(range) }
        } else if command {
            if r.selection.contains(url) { r.selection.remove(url) } else { r.selection.insert(url) }
            r.anchor = url
        } else {
            r.selection = [url]
            r.anchor = url
        }
        review = r
    }

    func selectAll() {
        guard var r = review else { return }
        r.selection = Set(r.pages)
        review = r
    }

    func removeSelected() {
        guard var r = review, !r.locked, !r.selection.isEmpty else { return }
        r.pages.removeAll { r.selection.contains($0) }
        r.selection = []
        r.anchor = nil
        review = r
    }

    func savePDF() {
        guard let r = review, !r.locked, !r.pages.isEmpty, let window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = "\(r.runName).pdf"
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        let pageBytes = r.pages.reduce(Int64(0)) { sum, url in
            sum + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        let sizeChoice = PDFSizeAccessory(pageBytes: pageBytes)
        panel.accessoryView = sizeChoice.view
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            sizeChoice.remember()
            self?.export(to: url, size: sizeChoice.selected)
        }
    }

    private func export(to url: URL, size: PDFSize) {
        guard let list = review?.pages else { return }
        review?.saving = true
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result { try PDFExporter.export(imageURLs: list, to: url, size: size) }
            }.value
            review?.saving = false
            switch result {
            case .success:
                let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
                review?.savedPDF = url
                review?.savedCount = list.count
                review?.savedBytes = bytes
                Log.write("PDF saved: \(url.path), \(list.count) pages, size \(size.rawValue), \(bytes ?? -1) bytes")
            case .failure(let error):
                Log.write("PDF export failed: \(error)")
                alert = AlertItem(title: "Could not save the PDF",
                                  message: "\(error)\n\nThe cached images are kept in \(review?.cacheDir.path ?? "the cache").")
            }
        }
    }

    func showSavedInFinder() {
        guard let url = review?.savedPDF else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func trashCache() {
        guard let r = review, r.savedPDF != nil, !r.locked else { return }
        do {
            try FileManager.default.trashItem(at: r.cacheDir, resultingItemURL: nil)
            review?.cacheTrashed = true
            Log.write("cache moved to Trash: \(r.cacheDir.path)")
        } catch {
            alert = AlertItem(title: "Could not delete the cached images", message: error.localizedDescription)
        }
    }

    /// Back to setup with the same source window preselected.
    func newCapture() {
        review = nil
        runNameText = ""
        refreshPermissions()
        stage = .setup
    }
}
