import AppKit
import ImageIO
import ScreenCaptureKit
import ScreenshoterCore
import SwiftUI
import UniformTypeIdentifiers

/// Hidden `--ui-snapshots <dir>` mode for UI review. Builds every screen state with mock data
/// (no Screen Recording, no Accessibility, no capture), hosts the real SwiftUI views in
/// off-screen windows at the real window sizes and writes `<NN>-<state>-light.png` and
/// `-dark.png` at 2×. Alerts and confirmation dialogs (system sheets) go to `dialogs.txt`.
enum UISnapshots {
    static func run(outDir: String) -> Never {
        let out = URL(fileURLWithPath: (outDir as NSString).expandingTildeInPath, isDirectory: true)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let runner = Runner(out: out)
        app.delegate = runner
        app.run()
        exit(ExitCode.failure)   // not reached: the runner exits
    }

    private final class Runner: NSObject, NSApplicationDelegate {
        let out: URL
        init(out: URL) { self.out = out }

        func applicationDidFinishLaunching(_ notification: Notification) {
            Task { @MainActor in
                do {
                    try await Snapshotter(out: out).renderAll()
                    exit(ExitCode.ok)
                } catch {
                    FileHandle.standardError.write(Data("ui-snapshots failed: \(error)\n".utf8))
                    exit(ExitCode.failure)
                }
            }
        }
    }
}

// MARK: - States

@MainActor
private final class Snapshotter {
    let out: URL
    let mock: MockData
    var count = 0

    init(out: URL) throws {
        self.out = out
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        // Fixed settings for every model: read-only argument domain, nothing is written to disk.
        UserDefaults.standard.setVolatileDomain([
            "nextKey": NextKey.pageDown.rawValue,
            "extraLatency": 0.5,
            "maxPages": 500,
            "splitSpreads": true,
            PDFSizeAccessory.defaultsKey: PDFSize.balanced.rawValue,
        ], forName: UserDefaults.argumentDomain)
        mock = try MockData()
    }

    func renderAll() async throws {
        await mock.warmThumbnails()

        // Setup screen (940 × 620, the window's setup size).
        try await setup("setup-first-launch") { m in
            m.runningFromTerminal = false
        }
        try await setup("setup-first-launch-terminal") { m in
            m.runningFromTerminal = true
        }
        try await setup("setup-first-launch-min-size", size: Theme.setupMinSize) { m in
            m.runningFromTerminal = false
        }
        try await setup("setup-screen-relaunch") { m in
            m.runningFromTerminal = false
            m.permissions = PermissionState(screen: .needsRelaunch, accessibility: false)
            m.screenRequested = true
        }
        try await setup("setup-screen-relaunch-terminal") { m in
            m.runningFromTerminal = true
            m.permissions = PermissionState(screen: .needsRelaunch, accessibility: true)
            m.screenRequested = true
        }
        try await setup("setup-accessibility-needed") { m in
            m.runningFromTerminal = false
            m.permissions = PermissionState(screen: .granted, accessibility: false)
        }
        try await setup("setup-no-window") { m in
            m.permissions = .all
        }
        try await setup("setup-permissions-expanded") { m in
            m.permissions = .all
            m.permissionsExpanded = true
        }
        try await setup("setup-window-loading") { m in
            m.permissions = .all
            m.source = self.mock.playBooksWindow
        }
        try await setup("setup-ready") { m in
            self.ready(m)
        }
        try await setup("setup-test-key-sent") { m in
            self.ready(m)
            m.testKeyMessage = "Sent \(NextKey.pageDown.displayName). Did the page turn?"
        }
        try await setup("setup-test-key-failed") { m in
            self.ready(m)
            m.testKeyMessage = "Could not send the key: the picked window (Safari) could not be brought to the front; keys would go to another app"
        }
        try await setup("setup-other-app-window") { m in
            m.permissions = .all
            m.source = self.mock.otherWindow
            m.sourceThumbnail = self.mock.otherThumbnail
        }
        try await setup("setup-window-offscreen") { m in
            self.ready(m)
            m.sourceHealth = .offScreen
        }
        try await setup("setup-window-closed") { m in
            self.ready(m)
            m.sourceHealth = .gone
        }
        try await setup("setup-window-no-screen-permission") { m in
            self.ready(m)
            m.permissions = PermissionState(screen: .needsRelaunch, accessibility: true)
            m.screenRequested = true
            m.runningFromTerminal = false
        }

        // "Choose from list" / "Change" popover content (400 pt wide, height fits the content).
        try await windowList("window-list") { m in
            m.permissions = .all
            m.source = self.mock.playBooksWindow
            let list = self.mock.windowList
            m.mockWindowList = { list }
        }
        try await windowList("window-list-loading") { m in
            m.permissions = .all
            m.mockWindowList = {
                try? await Task.sleep(for: .seconds(3600))
                return []
            }
        }
        try await windowList("window-list-no-permission") { m in
            m.permissions = PermissionState(screen: .needed, accessibility: true)
        }
        try await windowList("window-list-empty") { m in
            m.permissions = .all
            m.mockWindowList = { [] }
        }

        // Capture HUD (360 × 128 floating panel).
        try await hud("hud-starting") { m in
            m.progress = CaptureProgress(pageCount: 0, lastPage: nil, status: "Starting…",
                                         startedAt: Date().addingTimeInterval(-1))
        }
        try await hud("hud-capturing") { m in
            let page = self.mock.pages[36]
            m.progress = CaptureProgress(pageCount: 37, lastPage: page, status: "Saved page 37",
                                         startedAt: Date().addingTimeInterval(-83))
            m.lastPageThumb = self.mock.hudThumb(page)
        }
        try await hud("hud-stopping") { m in
            let page = self.mock.pages[51]
            m.progress = CaptureProgress(pageCount: 52, lastPage: page, status: "Stopping…",
                                         startedAt: Date().addingTimeInterval(-127))
            m.lastPageThumb = self.mock.hudThumb(page)
        }

        // Review (900 × 700, the window's review size).
        let pages = mock.pages
        try await review("review-end-of-book") { r in
            r = self.mock.review(pages, .endOfDocument)
        }
        try await review("review-selection") { r in
            r = self.mock.review(pages, .endOfDocument)
            r.selection = Set(pages[1...3])
            r.anchor = pages[1]
        }
        try await review("review-incomplete-selected") { r in
            r = self.mock.review(pages, .endOfDocument)
            r.selection = r.incomplete
        }
        try await review("review-saving") { r in
            r = self.mock.review(pages, .endOfDocument)
            r.saving = true
        }
        try await review("review-saved") { r in
            r = self.mock.saved(self.mock.review(pages, .endOfDocument))
        }
        try await review("review-saved-cache-trashed") { r in
            r = self.mock.saved(self.mock.review(pages, .endOfDocument))
            r.cacheTrashed = true
        }
        try await review("review-cache-trashed-no-pdf") { r in
            r = self.mock.review(pages, .endOfDocument)
            r.cacheTrashed = true
        }
        try await review("review-pages-removed") { r in
            r = self.mock.review(pages, .endOfDocument)
            let gone = Set(r.incomplete).union([pages[0]])
            r.pages.removeAll { gone.contains($0) }
            r.incomplete = []
        }
        try await review("review-cap-reached") { r in
            r = self.mock.review(Array(pages.prefix(40)), .capReached)
        }
        try await review("review-cancelled") { r in
            r = self.mock.review(Array(pages.prefix(23)), .cancelled)
        }
        try await review("review-capture-failed") { r in
            r = self.mock.review(Array(pages.prefix(9)),
                                 .captureFailed("the page never turned — the key did not reach the window"))
        }
        try await review("review-zero-pages") { r in
            r = self.mock.review([], .captureFailed("the page never turned — the key did not reach the window"))
        }
        try await review("review-all-removed") { r in
            r = self.mock.review(Array(pages.prefix(5)), .cancelled)
            r.pages = []
        }
        try await review("review-headless", headless: true) { r in
            r = self.mock.review(pages, .endOfDocument)
        }

        // Page viewer sheet content (840 × 620: review window minus the sheet margins).
        try await renderBoth("page-viewer", size: NSSize(width: 840, height: 620), titled: false, wait: 1.0) {
            let m = self.model()
            m.review = self.mock.review(pages, .endOfDocument)
            m.stage = .review
            return Self.hosting(PageViewer(model: m, start: pages[2]).tint(Theme.accent)
                .background(Color(nsColor: .windowBackgroundColor)))
        }

        // Save panel accessory (the save panel itself is a system window).
        let accSize = NSSize(width: 460, height: PDFSizeAccessory(pageBytes: 61_400_000).view.frame.height)
        try await renderBoth("pdf-size-accessory", size: accSize, titled: false, wait: 0.2) {
            let acc = PDFSizeAccessory(pageBytes: 61_400_000)
            let box = FillView(frame: NSRect(origin: .zero, size: accSize))
            acc.view.frame.origin.x = (accSize.width - acc.view.frame.width) / 2
            box.addSubview(acc.view)
            return box
        }

        try writeDialogs()
        print("ui-snapshots: \(count) states, \(count * 2) PNG files + dialogs.txt in \(out.path)")
    }

    // MARK: State helpers

    func model() -> AppModel {
        let m = AppModel()
        m.stopPolling()
        m.permissions = PermissionState(screen: .needed, accessibility: false)
        m.screenRequested = false
        m.runningFromTerminal = false
        return m
    }

    func ready(_ m: AppModel) {
        m.permissions = .all
        m.source = mock.playBooksWindow
        m.sourceThumbnail = mock.sourceThumbnail
        m.sourceHealth = .ok
    }

    func setup(_ name: String, size: NSSize = Theme.setupSize, _ configure: @escaping (AppModel) -> Void) async throws {
        try await renderBoth(name, size: size, titled: true, wait: 0.6) {
            let m = self.model()
            configure(m)
            return Self.hosting(RootView(model: m))
        }
    }

    func review(_ name: String, headless: Bool = false, _ configure: @escaping (inout ReviewState) -> Void) async throws {
        try await renderBoth(name, size: Theme.reviewSize, titled: true, wait: 0.8) {
            let m = self.model()
            m.permissions = .all
            m.headless = headless
            var r = self.mock.review([], .endOfDocument)
            configure(&r)
            m.review = r
            m.stage = .review
            return Self.hosting(RootView(model: m))
        }
    }

    func windowList(_ name: String, _ configure: @escaping (AppModel) -> Void) async throws {
        try await renderBoth(name, size: nil, titled: false, wait: 0.6) {
            let m = self.model()
            configure(m)
            return Self.hosting(fit: true, WindowListView(model: m) { _ in }
                .tint(Theme.accent)
                .background(Color(nsColor: .windowBackgroundColor)))
        }
    }

    /// Same view tree as `CaptureHUDController`: HUD material + `CaptureHUDView`, dark, over a
    /// grey desktop so the material has something to show.
    func hud(_ name: String, _ configure: @escaping (AppModel) -> Void) async throws {
        let size = CaptureHUDController.size
        let margin: CGFloat = 24
        let outer = NSSize(width: size.width + margin * 2, height: size.height + margin * 2)
        try await renderBoth(name, size: outer, titled: false, wait: 0.6) {
            let m = self.model()
            m.stage = .capturing
            configure(m)
            let desk = NSView(frame: NSRect(origin: .zero, size: outer))
            desk.wantsLayer = true
            desk.layer?.backgroundColor = NSColor(calibratedWhite: 0.42, alpha: 1).cgColor
            let effect = NSVisualEffectView(frame: NSRect(origin: NSPoint(x: margin, y: margin), size: size))
            effect.material = .hudWindow
            effect.blendingMode = .withinWindow
            effect.state = .active
            effect.maskImage = Self.roundedMask(radius: 14)
            effect.appearance = NSAppearance(named: .darkAqua)
            let host = NSHostingView(rootView: CaptureHUDView(model: m).tint(Theme.accent)
                .environment(\.controlActiveState, .key))
            host.frame = effect.bounds
            host.autoresizingMask = [.width, .height]
            effect.addSubview(host)
            desk.addSubview(effect)
            return desk
        }
    }

    /// Hosting view the window sizes, like MainWindowController's (`sizingOptions = []`).
    /// `fit`: keep the default sizing options, so `fittingSize` gives the content height.
    static func hosting<V: View>(fit: Bool = false, _ view: V) -> NSView {
        let host = NSHostingView(rootView: view.environment(\.controlActiveState, .key))
        if !fit { host.sizingOptions = [] }
        return host
    }

    static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }

    // MARK: Rendering

    /// Renders the view in light and dark. `size` nil = the view's fitting size.
    func renderBoth(_ name: String, size: NSSize?, titled: Bool, wait: Double,
                    _ make: @escaping () -> NSView) async throws {
        count += 1
        let base = String(format: "%02d-%@", count, name)
        for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let url = out.appendingPathComponent("\(base)-\(suffix).png")
            try await render(make(), size: size, titled: titled, appearance: appearance, wait: wait, to: url)
        }
        print("rendered \(base)")
    }

    func render(_ view: NSView, size: NSSize?, titled: Bool, appearance name: NSAppearance.Name,
                wait: Double, to url: URL) async throws {
        let appearance = NSAppearance(named: name)!
        let start = size ?? NSSize(width: view.frame.width > 0 ? view.frame.width : 400, height: 600)
        let window = SnapshotWindow(contentRect: NSRect(origin: .zero, size: start),
                              styleMask: titled ? [.titled, .closable, .miniaturizable, .resizable] : [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = appearance
        if titled {
            // Same window setup as MainWindowController.
            window.title = AppInfo.name
            window.titlebarAppearsTransparent = true
            window.toolbarStyle = .unified
        } else {
            window.isOpaque = false
            window.backgroundColor = .clear
        }
        window.contentView = view
        window.alphaValue = 0   // in the window list so SwiftUI tasks run, but never visible
        window.ignoresMouseEvents = true
        window.orderFrontRegardless()
        window.makeKey()
        defer { window.orderOut(nil); window.close() }

        try await Task.sleep(for: .seconds(wait))
        if size == nil {
            let fit = view.fittingSize
            window.setContentSize(NSSize(width: start.width, height: max(fit.height, 40)))
            try await Task.sleep(for: .seconds(0.2))
        }
        view.layoutSubtreeIfNeeded()
        window.displayIfNeeded()

        // Titled: the whole frame (titlebar + content); else the content view.
        let target = titled ? (window.contentView?.superview ?? view) : view
        let bounds = target.bounds
        let scale: CGFloat = 2
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: Int(bounds.width * scale), pixelsHigh: Int(bounds.height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { throw SnapshotError.bitmap(url.lastPathComponent) }
        rep.size = bounds.size
        appearance.performAsCurrentDrawingAppearance {
            target.cacheDisplay(in: bounds, to: rep)
        }
        guard let png = rep.representation(using: .png, properties: [:]) else {
            throw SnapshotError.bitmap(url.lastPathComponent)
        }
        try png.write(to: url)
    }

    enum SnapshotError: Error { case bitmap(String) }

    // MARK: Dialogs (system sheets, not rendered)

    func writeDialogs() throws {
        let cacheDir = mock.cacheDir.path
        let n = mock.pages.count
        let text = """
        Alerts and confirmation dialogs. SwiftUI shows them as system sheets on the main window;
        they are not rendered off-screen. Strings as the code builds them, with mock values.

        D1 Alert (RootView .alert, AppDelegate.startCapture: session setup throws)
           Title:   Cannot start the capture
           Message: <error, e.g. noOwningApp>
           Buttons: OK

        D2 Alert (AppModel.relaunch: NSWorkspace cannot open the bundle)
           Title:   Cannot relaunch
           Message: <localizedDescription>\\n\\nQuit \(AppInfo.name) and open it again.
           Buttons: OK

        D3 Alert (AppModel.showSource: CGKeySender.bringToFront throws)
           Title:   Cannot show the window
           Message: <KeySenderError, e.g. "the picked window (Safari) could not be brought to the front; keys would go to another app">
           Buttons: OK

        D4 Alert (AppModel.export: PDFExporter throws)
           Title:   Could not save the PDF
           Message: <error>\\n\\nThe cached images are kept in \(cacheDir).
           Buttons: OK

        D5 Alert (AppModel.trashCache: trashItem throws)
           Title:   Could not delete the cached images
           Message: <localizedDescription>
           Buttons: OK

        D6 Confirmation dialog (ReviewView "Delete cached images" with no PDF saved)
           Title:   Delete the \(n) captured pages?
           Message: No PDF was saved from this run.
           Buttons: Delete (destructive), Cancel

        System windows, not rendered:
        S1 NSSavePanel "Save PDF…" (name "<run name>.pdf", folder ~/Downloads, PDF size accessory = pdf-size-accessory PNG)
        S2 Click-a-window overlay (WindowPicker.PickerOverlay): every screen tinted systemBlue 8 %, crosshair cursor, ESC cancels
        S3 macOS Screen Recording / Accessibility / private-window-picker prompts (owned by macOS)
        """
        try text.write(to: out.appendingPathComponent("dialogs.txt"), atomically: true, encoding: .utf8)
    }
}

/// Draws as the key, main window of an active app (accent buttons, coloured traffic lights),
/// although it is invisible and the app is in the background.
private final class SnapshotWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override var isKeyWindow: Bool { true }
    override var isMainWindow: Bool { true }
}

/// Window-background fill that follows the view's appearance (a layer colour would not).
private final class FillView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
    }
}

private extension PermissionState {
    static let all = PermissionState(screen: .granted, accessibility: true)
}

// MARK: - Mock data

@MainActor
private final class MockData {
    let dir: URL
    let pages: [URL]
    let shortPages: Set<URL>
    let cacheDir: URL
    let runDate = Date(timeIntervalSince1970: 1_794_809_700)   // 2026-11-16 06:15 UTC
    let sourceThumbnail: CGImage
    let otherThumbnail: CGImage
    let playBooksWindow: SourceWindow
    let otherWindow: SourceWindow
    let windowList: [SourceWindow]

    init() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gpbd-ui-snapshots-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        cacheDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/\(AppInfo.cliName)/\(CachePaths.defaultRunName(date: runDate))")

        // 64 pages: cover, text pages, comic pages every 7th, an illustration, 2 cut-off pages.
        var urls: [URL] = []
        var short: Set<URL> = []
        for i in 1...64 {
            let image: CGImage
            var isShort = false
            switch i {
            case 1: image = Art.cover(width: 1100, height: 1500)
            case 64: image = Art.cover(width: 1100, height: 1500, back: true)
            case 12, 41: image = Art.textPage(width: 1100, height: 620, seed: i); isShort = true
            case _ where i % 7 == 0: image = Art.comicPage(width: 1100, height: 1500, seed: i)
            case 5: image = Art.illustration(width: 1100, height: 1500)
            default: image = Art.textPage(width: 1100, height: 1500, seed: i)
            }
            let url = dir.appendingPathComponent(String(format: "%04d.jpg", i))
            try Art.writeJPEG(image, to: url)
            urls.append(url)
            if isShort { short.insert(url) }
        }
        pages = urls
        shortPages = short
        sourceThumbnail = Art.browserWindow(width: 640, height: 400)
        otherThumbnail = Art.previewWindow(width: 640, height: 420)

        let safari = NSWorkspace.shared.icon(forFile: "/Applications/Safari.app")
        let preview = NSWorkspace.shared.icon(forFile: "/System/Applications/Preview.app")
        let finder = NSWorkspace.shared.icon(forFile: "/System/Library/CoreServices/Finder.app")
        let notes = NSWorkspace.shared.icon(forFile: "/System/Applications/Notes.app")
        playBooksWindow = SourceWindow(mockID: 101, appName: "Safari", title: "The Long Way Home — Google Play Books",
                                       icon: safari, frame: CGRect(x: 80, y: 60, width: 1280, height: 800))
        otherWindow = SourceWindow(mockID: 102, appName: "Preview", title: "",
                                   icon: preview, frame: CGRect(x: 200, y: 120, width: 900, height: 1180))
        windowList = [
            playBooksWindow,
            SourceWindow(mockID: 103, appName: "Safari", title: "Inbox (3) — Mail", icon: safari,
                         frame: CGRect(x: 0, y: 30, width: 1200, height: 760)),
            SourceWindow(mockID: 102, appName: "Preview", title: "scan-2025-11-02.pdf", icon: preview,
                         frame: CGRect(x: 200, y: 120, width: 900, height: 1180)),
            SourceWindow(mockID: 104, appName: "Finder", title: "Downloads", icon: finder,
                         frame: CGRect(x: 300, y: 200, width: 800, height: 500)),
            SourceWindow(mockID: 105, appName: "Notes", title: "Reading list", icon: notes,
                         frame: CGRect(x: 400, y: 160, width: 700, height: 520)),
        ]
    }

    /// Decodes the review-grid thumbnails (400 px) up front, so the first frame shows them.
    func warmThumbnails() async {
        for url in pages {
            _ = await Thumbnails.image(for: url, maxPixel: 400)
            _ = await Thumbnails.image(for: url, maxPixel: 240)
        }
    }

    func hudThumb(_ url: URL) -> NSImage? { Thumbnails.cached(url, maxPixel: 240) }

    func review(_ list: [URL], _ reason: StopReason) -> ReviewState {
        var r = ReviewState(pages: list, reason: reason, cacheDir: cacheDir,
                            duration: Double(list.count) * 2.3 + 4)
        r.incomplete = Set(list.filter { shortPages.contains($0) })
        return r
    }

    func saved(_ r: ReviewState) -> ReviewState {
        var r = r
        r.savedPDF = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Downloads/\(r.runName).pdf")
        r.savedCount = r.pages.count
        r.savedBytes = 38_700_000
        return r
    }
}

private extension SourceWindow {
    /// Mock window: an empty SCWindow (its init is unavailable, so allocated through the
    /// runtime) with only `windowID` set, used for `id`.
    init(mockID: CGWindowID, appName: String, title: String, icon: NSImage?, frame: CGRect) {
        let w = (SCWindow.self as AnyObject).perform(NSSelectorFromString("alloc")).takeRetainedValue() as! SCWindow
        if class_getInstanceVariable(SCWindow.self, "_windowID") != nil {
            w.setValue(NSNumber(value: mockID), forKey: "windowID")
        }
        self.window = w
        self.appName = appName
        self.title = title
        self.pid = 0
        self.appIcon = icon
        self.frame = frame
    }
}

// MARK: - Synthetic images

private enum Art {
    static func context(_ w: Int, _ h: Int) -> CGContext {
        CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    }

    static func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: r, green: g, blue: b, alpha: a)
    }

    /// Deterministic pseudo-random in 0..<1.
    static func rand(_ seed: Int, _ n: Int) -> CGFloat {
        var x = UInt64(truncatingIfNeeded: seed &* 2654435761 &+ n &* 40503 &+ 12345)
        x ^= x >> 13; x &*= 0x5bd1e995; x ^= x >> 15
        return CGFloat(x % 10_000) / 10_000
    }

    /// Paper page with grey text-line bars (CG origin bottom-left; we draw top-down).
    static func textPage(width w: Int, height h: Int, seed: Int) -> CGImage {
        let c = context(w, h)
        c.setFillColor(rgb(0.985, 0.978, 0.962))
        c.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let margin = CGFloat(w) * 0.12
        let lineH: CGFloat = 16, gap: CGFloat = 20
        var y = CGFloat(h) - margin
        if seed % 9 == 2 {   // chapter opening
            y -= 120
            c.setFillColor(rgb(0.25, 0.25, 0.27))
            c.fill(CGRect(x: margin, y: y, width: CGFloat(w) * 0.45, height: 34))
            y -= 90
        }
        var line = 0
        c.setFillColor(rgb(0.55, 0.55, 0.57))
        while y > margin + 60 {
            line += 1
            let paraEnd = rand(seed, line) < 0.12
            let indent: CGFloat = (line == 1 || rand(seed, line - 1) < 0.12) ? 40 : 0
            let full = CGFloat(w) - margin * 2 - indent
            let len = paraEnd ? full * (0.25 + rand(seed, line + 99) * 0.5) : full * (0.94 + rand(seed, line + 7) * 0.06)
            c.fill(CGRect(x: margin + indent, y: y - lineH, width: len, height: lineH))
            y -= lineH + gap + (paraEnd ? 14 : 0)
        }
        c.setFillColor(rgb(0.6, 0.6, 0.62))
        c.fill(CGRect(x: CGFloat(w) / 2 - 18, y: margin * 0.5, width: 36, height: 12))   // folio
        return c.makeImage()!
    }

    static func comicPage(width w: Int, height h: Int, seed: Int) -> CGImage {
        let c = context(w, h)
        c.setFillColor(rgb(0.99, 0.99, 0.98))
        c.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let palette = [rgb(0.93, 0.42, 0.33), rgb(0.27, 0.55, 0.80), rgb(0.98, 0.80, 0.30),
                       rgb(0.40, 0.72, 0.48), rgb(0.62, 0.45, 0.78), rgb(0.95, 0.62, 0.30)]
        let m: CGFloat = 50, g: CGFloat = 24
        let W = CGFloat(w) - 2 * m, H = CGFloat(h) - 2 * m
        let rowH = (H - 2 * g) / 3
        var k = 0
        for row in 0..<3 {
            let y = m + CGFloat(2 - row) * (rowH + g)
            let split = 0.35 + rand(seed, row) * 0.3
            let cols: [(CGFloat, CGFloat)] = row == 1 ? [(0, W)] : [(0, W * split - g / 2), (W * split + g / 2, W * (1 - split) - g / 2)]
            for (x, width) in cols {
                let r = CGRect(x: m + x, y: y, width: width, height: rowH)
                c.setFillColor(palette[(seed + k) % palette.count])
                c.fill(r)
                // simple shapes: a "figure" and a speech bubble
                c.setFillColor(rgb(1, 1, 1, 0.85))
                c.fillEllipse(in: CGRect(x: r.minX + 24, y: r.maxY - 110, width: min(220, r.width * 0.5), height: 80))
                c.setFillColor(rgb(0.15, 0.15, 0.2, 0.75))
                c.fillEllipse(in: CGRect(x: r.midX - 40, y: r.minY + 30, width: 80, height: 80))
                c.fill(CGRect(x: r.midX - 30, y: r.minY, width: 60, height: 40))
                c.setStrokeColor(rgb(0.08, 0.08, 0.1))
                c.setLineWidth(6)
                c.stroke(r)
                k += 1
            }
        }
        return c.makeImage()!
    }

    static func illustration(width w: Int, height h: Int) -> CGImage {
        let c = context(w, h)
        c.setFillColor(rgb(0.985, 0.978, 0.962))
        c.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let r = CGRect(x: 130, y: 420, width: CGFloat(w) - 260, height: CGFloat(h) - 600)
        let grad = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [
            rgb(0.55, 0.70, 0.85), rgb(0.93, 0.85, 0.70)] as CFArray, locations: [0, 1])!
        c.saveGState(); c.clip(to: r)
        c.drawLinearGradient(grad, start: CGPoint(x: 0, y: r.maxY), end: CGPoint(x: 0, y: r.minY), options: [])
        c.setFillColor(rgb(0.30, 0.42, 0.36))
        c.fillEllipse(in: CGRect(x: r.minX - 100, y: r.minY - 300, width: r.width * 0.9, height: 520))
        c.setFillColor(rgb(0.22, 0.33, 0.30))
        c.fillEllipse(in: CGRect(x: r.midX - 80, y: r.minY - 360, width: r.width * 0.8, height: 560))
        c.restoreGState()
        c.setFillColor(rgb(0.55, 0.55, 0.57))
        for i in 0..<4 { c.fill(CGRect(x: 160, y: 330 - CGFloat(i) * 36, width: CGFloat(w) - 320 - CGFloat(i == 3 ? 300 : 0), height: 16)) }
        return c.makeImage()!
    }

    static func cover(width w: Int, height h: Int, back: Bool = false) -> CGImage {
        let c = context(w, h)
        c.setFillColor(back ? rgb(0.16, 0.24, 0.30) : rgb(0.12, 0.30, 0.36))
        c.fill(CGRect(x: 0, y: 0, width: w, height: h))
        c.setFillColor(rgb(0.95, 0.72, 0.36))
        if back {
            for i in 0..<6 { c.fill(CGRect(x: 160, y: CGFloat(h) - 400 - CGFloat(i) * 40, width: CGFloat(w) - 320, height: 14)) }
            c.setFillColor(rgb(1, 1, 1))
            c.fill(CGRect(x: CGFloat(w) - 420, y: 120, width: 260, height: 140))   // barcode box
        } else {
            c.fill(CGRect(x: 120, y: CGFloat(h) - 420, width: CGFloat(w) - 240, height: 90))
            c.fill(CGRect(x: 120, y: CGFloat(h) - 540, width: CGFloat(w) * 0.5, height: 60))
            c.setFillColor(rgb(0.95, 0.72, 0.36, 0.25))
            c.fillEllipse(in: CGRect(x: CGFloat(w) / 2 - 300, y: 260, width: 600, height: 600))
            c.setFillColor(rgb(0.93, 0.93, 0.9))
            c.fill(CGRect(x: 120, y: 140, width: 360, height: 34))
        }
        return c.makeImage()!
    }

    /// Browser window with the Play Books reader, two-page spread.
    static func browserWindow(width w: Int, height h: Int) -> CGImage {
        let c = context(w, h)
        let W = CGFloat(w), H = CGFloat(h)
        c.setFillColor(rgb(0.93, 0.93, 0.94))
        c.fill(CGRect(x: 0, y: 0, width: W, height: H))
        c.setFillColor(rgb(0.86, 0.86, 0.88))   // toolbar
        c.fill(CGRect(x: 0, y: H - 44, width: W, height: 44))
        for (i, col) in [rgb(1, 0.37, 0.34), rgb(1, 0.74, 0.2), rgb(0.16, 0.79, 0.25)].enumerated() {
            c.setFillColor(col); c.fillEllipse(in: CGRect(x: 12 + CGFloat(i) * 16, y: H - 28, width: 10, height: 10))
        }
        c.setFillColor(rgb(1, 1, 1)); c.fill(CGRect(x: W * 0.28, y: H - 34, width: W * 0.44, height: 22))
        c.setFillColor(rgb(1, 1, 1)); c.fill(CGRect(x: 0, y: H - 80, width: W, height: 36))   // reader bar
        c.setFillColor(rgb(0.35, 0.35, 0.38)); c.fill(CGRect(x: 18, y: H - 66, width: 140, height: 10))
        c.setFillColor(rgb(0.97, 0.97, 0.97)); c.fill(CGRect(x: 0, y: 0, width: W, height: H - 80))
        let pageW = W * 0.33, pageH = (H - 80) * 0.86
        let y = (H - 80 - pageH) / 2
        for (i, x) in [W / 2 - pageW, W / 2].enumerated() {
            let r = CGRect(x: x, y: y, width: pageW, height: pageH)
            c.setFillColor(rgb(0, 0, 0, 0.08)); c.fill(r.offsetBy(dx: 0, dy: -2))
            c.draw(textPage(width: 330, height: 450, seed: 20 + i), in: r)
        }
        return c.makeImage()!
    }

    static func previewWindow(width w: Int, height h: Int) -> CGImage {
        let c = context(w, h)
        let W = CGFloat(w), H = CGFloat(h)
        c.setFillColor(rgb(0.80, 0.80, 0.82)); c.fill(CGRect(x: 0, y: 0, width: W, height: H))
        c.setFillColor(rgb(0.90, 0.90, 0.92)); c.fill(CGRect(x: 0, y: H - 40, width: W, height: 40))
        let r = CGRect(x: W * 0.3, y: 16, width: W * 0.4, height: H - 72)
        c.draw(textPage(width: 400, height: 560, seed: 3), in: r)
        return c.makeImage()!
    }

    static func writeJPEG(_ image: CGImage, to url: URL) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
    }
}
