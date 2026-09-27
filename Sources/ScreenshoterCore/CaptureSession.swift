import CoreGraphics
import Foundation

public protocol WindowCapturer: AnyObject {
    /// Full shot at backing resolution.
    func captureFull() async throws -> CGImage
    /// Any size; the session scales it to full / `config.previewDownscale`.
    func capturePreview() async throws -> CGImage
}

public protocol PageTurner: AnyObject {
    func turnPage() throws
}

public protocol SessionClock: AnyObject {
    func now() -> TimeInterval
    func sleep(_ seconds: Double) async throws
}

public enum StopReason: Equatable {
    case endOfDocument, capReached, cancelled, captureFailed(String)
}

public struct SessionResult {
    public var pages: [URL]
    public var reason: StopReason
    /// Page zone in full-res px, nil if it was never found.
    public var zone: PixelRect?

    public init(pages: [URL], reason: StopReason, zone: PixelRect?) {
        self.pages = pages
        self.reason = reason
        self.zone = zone
    }
}

/// Capture loop: turn page, wait for change, wait for stable, shoot, crop, save.
/// All waiting goes through `SessionClock.sleep`. See plan "Session algorithm".
public final class CaptureSession {
    private let config: SessionConfig
    private let capturer: WindowCapturer
    private let turner: PageTurner
    private let clock: SessionClock
    private let sink: PageSink
    private let log: (String) -> Void
    /// Preview downscale factor, at least 1.
    private let d: Int

    private let lock = NSLock()
    private var cancelled = false

    /// Called after each saved page with (pages saved so far, file URL). Runs on the thread
    /// `run()` runs on, not the main thread; UI code must hop to main itself. Set before `run()`.
    public var onPageSaved: ((Int, URL) -> Void)?
    /// Short human status ("Turning page…", "Waiting for the page to settle…", "Saved page N").
    /// Same threading as `onPageSaved`.
    public var onStatus: ((String) -> Void)?
    /// Called once at the end of a run whose page list changed after the fact: a tiny end
    /// screen was dropped and/or the split last shot (back cover) was merged into one file.
    /// Gets the complete new page list, same as `SessionResult.pages`. The UI replaces its
    /// list with it. Same threading as `onPageSaved`.
    public var onPagesReplaced: (([URL]) -> Void)?

    // Run state.
    private var saved: [URL] = []
    /// Last saved shot: full-res image, unsplit page rect, number of files written for it.
    /// Kept so the back cover can be re-cropped whole at the end.
    /// The last two saved shots: full-res image, unsplit page rect, files written. Two, because
    /// a tiny end screen may be dropped and the shot before it merged.
    private var recentShots: [(full: CGImage, rect: PixelRect, files: Int)] = []
    /// Unsplit page-rect area (full px) of every saved shot, for the end-screen test.
    private var shotAreas: [Int] = []
    private var zone: PixelRect?          // preview coordinates
    private var previewWidth = 0, previewHeight = 0
    private var noChange = 0
    /// Small gray thumb (≤ `thumbWidth` px wide) of the preview of every saved shot (per shot,
    /// before split), in order. Wrap-check hashes come from these, so they follow zone changes.
    private var shotThumbs: [GrayImage] = []
    /// Wrap hash per entry of `shotThumbs`, valid for `wrapHashZone`; dropped when the zone changes.
    private var wrapHashes: [PageHash] = []
    private var wrapHashZone: PixelRect?
    /// 320, not 160: at 160 px a 2-up cover is ~40 px wide, and a 1% zoom or a few px of shift
    /// between two renders of the same page moved its hash by up to 52 bits (measured on a real
    /// comic cover). At 320 px the same cases stay ≤ 19.
    private let thumbWidth = 320
    /// Wrap-check match distance: looser than `matchDistance`, because the two shots compared
    /// are far apart in time (re-rendered, maybe slightly moved). Different real comic pages
    /// measured ≥ 90 apart.
    private var wrapDistance: Int { 2 * config.matchDistance }

    /// Zone growth > 2 blocks triggers a recompute.
    private let blockSize = PageZone.defaultBlockSize

    private enum Stop: Error { case cancelled, failed(String) }

    public init(config: SessionConfig, capturer: WindowCapturer, turner: PageTurner,
                clock: SessionClock, sink: PageSink, log: @escaping (String) -> Void) {
        self.config = config
        self.capturer = capturer
        self.turner = turner
        self.clock = clock
        self.sink = sink
        self.log = log
        self.d = max(config.previewDownscale, 1)
    }

    /// Thread-safe. `run()` returns `.cancelled` at its next poll.
    public func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    private var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    public func run() async -> SessionResult {
        saved = []
        recentShots = []
        shotAreas = []
        zone = nil
        noChange = 0
        shotThumbs = []
        wrapHashes = []
        wrapHashZone = nil
        var full0: CGImage?
        let reason: StopReason
        do {
            reason = try await loop(full0: &full0)
        } catch Stop.cancelled {
            reason = .cancelled
        } catch Stop.failed(let msg) {
            reason = .captureFailed(msg)
        } catch is CancellationError {
            reason = .cancelled
        } catch {
            reason = .captureFailed(String(describing: error))
        }
        log(reason == .capReached ? "\(reason.words) (\(config.maxPages))" : reason.words)

        // Zone never found: keep the first shot, trimmed on the whole image.
        if zone == nil, let full0 {
            do {
                try savePage(full0)
            } catch {
                log("failed to save first shot: \(error)")
            }
        }
        if reason == .endOfDocument {
            let before = saved
            dropEndScreen()
            mergeLastShot()
            if saved != before { onPagesReplaced?(saved) }
        }
        let fullZone = zone.map { $0.scaled(by: d).clamped(width: previewWidth * d, height: previewHeight * d) }
        return SessionResult(pages: saved, reason: reason, zone: fullZone)
    }

    // MARK: Loop

    private func loop(full0 full0Out: inout CGImage?) async throws -> StopReason {
        let full0 = try await captureFull()
        full0Out = full0
        (previewWidth, previewHeight) = config.previewSize(fullWidth: full0.width, fullHeight: full0.height)
        var prevPreview = try await capturePreviewGray()
        var prevHash = hash(prevPreview)   // recomputed whenever the zone changes

        while true {
            try checkCancel()
            if saved.count >= config.maxPages { return .capReached }

            // Turn and wait for change; two presses without change end the run.
            var changed = false
            while !changed {
                try turn()
                changed = try await waitForChange(from: prevHash)
                if !changed, noChangeHit("no change after key") { return .endOfDocument }
            }
            onStatus?("Waiting for the page to settle…")
            // noChange resets only when a page is saved (savePage), so a viewer that changes
            // and bounces back on every press still stops after 2 presses.

            try await sleep(config.extraLatency)
            let preview = try await waitPastPlaceholder(try await waitForStable(), before: prevPreview)
            let full = try await captureFull()

            if zone == nil {
                guard let z = PageZone.detect(before: prevPreview, after: preview, blockSize: blockSize) else {
                    if noChangeHit("change too small", counted: false) { return .endOfDocument }
                    continue
                }
                zone = z
                prevHash = hash(prevPreview)
                log("zone found \(z.scaled(by: d))")
                try savePage(full0)
                shotThumbs.append(thumb(prevPreview))
                full0Out = nil
            } else if let zoneNow = zone,
                      let comp = PageZone.detect(before: prevPreview, after: preview, blockSize: blockSize),
                      PageZone.exceeds(comp, zone: zoneNow, margin: 2 * blockSize) {
                zone = comp
                prevHash = hash(prevPreview)
                log("zone recomputed \(comp.scaled(by: d))")
            }

            let shotHash = hash(preview)
            if shotHash.distance(to: prevHash) <= config.matchDistance {
                if noChangeHit("shot matches last page, no change") { return .endOfDocument }
                continue
            }

            // Wrap check: a match with any earlier saved shot (not the last) means the viewer
            // went back to the start. Near-blank pages all look alike, so they are exempt.
            let shotThumb = thumb(preview)
            if !isBlank(preview, zone: zone ?? preview.bounds) {
                let h = wrapHash(shotThumb)
                if let i = currentWrapHashes().dropLast().firstIndex(where: { $0.distance(to: h) <= wrapDistance }) {
                    log("page matches page \(i + 1) — viewer wrapped, stopping")
                    return .endOfDocument
                }
            }

            try savePage(full)
            shotThumbs.append(shotThumb)
            prevPreview = preview
            prevHash = shotHash
        }
    }

    /// Counts a press or shot without a new page and logs `message`. True at the second one
    /// in a row (end of document). `counted` appends "(n/2)" to the message.
    private func noChangeHit(_ message: String, counted: Bool = true) -> Bool {
        noChange += 1
        log(counted ? "\(message) (\(noChange)/2)" : message)
        return noChange >= 2
    }

    /// Polls until the region hash moves more than `matchDistance` from `baseHash`.
    private func waitForChange(from baseHash: PageHash) async throws -> Bool {
        let start = clock.now()
        while true {
            try checkCancel()
            let p = try await capturePreviewGray()
            if hash(p).distance(to: baseHash) > config.matchDistance { return true }
            if clock.now() - start >= config.changeTimeout { return false }
            try await sleep(config.pollInterval)
        }
    }

    /// Polls until `stablePolls` consecutive hashes are within `stableDistance`. Timeout only logs.
    /// Returns the last polled preview (the stable one, or the latest frame on timeout).
    private func waitForStable() async throws -> GrayImage {
        let start = clock.now()
        var frame = try await capturePreviewGray()
        var last = hash(frame)
        var run = 1
        while run < config.stablePolls {
            if clock.now() - start >= config.settleTimeout {
                log("settle timeout on page \(saved.count + 1)")
                return frame
            }
            try await sleep(config.pollInterval)
            frame = try await capturePreviewGray()
            let cur = hash(frame)
            run = cur.distance(to: last) <= config.stableDistance ? run + 1 : 1
            last = cur
        }
        return frame
    }

    /// Viewers show a loading placeholder before an uncached page renders: a flat page, or a
    /// thin band while the page is still being laid out. If the settled shot is suspicious
    /// (see `suspicion`), polls up to `blankWait` for a change, then waits for stable again.
    /// Still suspicious at the end: taken as a real page and kept.
    /// Before the zone is known, the test runs on the area `detect` finds.
    private func waitPastPlaceholder(_ preview: GrayImage, before: GrayImage) async throws -> GrayImage {
        guard let region = zone ?? PageZone.detect(before: before, after: preview, blockSize: blockSize),
              var why = suspicion(preview, zone: region) else { return preview }
        let start = clock.now()
        var frame = preview
        var frameHash = hash(frame)
        while clock.now() - start < config.blankWait {
            try await sleep(config.pollInterval)
            let p = try await capturePreviewGray()
            guard hash(p).distance(to: frameHash) > config.matchDistance else { continue }
            frame = try await waitForStable()
            guard let w = suspicion(frame, zone: region) else { return frame }
            why = w
            frameHash = hash(frame)
        }
        // Before the zone exists, the first shot is saved ahead of this page.
        log("\(why) page \(saved.count + (zone == nil ? 2 : 1)) kept")
        return frame
    }

    /// "blank" if the segmented page is near-blank, "suspicious" if it is < 60% of the zone
    /// height or < 25% of its width (a page still loading as a thin band), nil if it looks fine.
    private func suspicion(_ preview: GrayImage, zone: PixelRect) -> String? {
        if isBlank(preview, zone: zone) { return "blank" }
        let page = PageZone.segment(preview, zone: zone)
        if Double(page.height) < 0.6 * Double(zone.height) || Double(page.width) < 0.25 * Double(zone.width) {
            return "suspicious"
        }
        return nil
    }

    // MARK: Page pipeline

    /// After the last page Play Books shows a small "next in the series" screen. If the last
    /// shot's page rect is < 35% of the median shot area, its files are dropped (the sink sets
    /// them aside). On failure the files stay and the failure is logged.
    private func dropEndScreen() {
        guard shotAreas.count >= 2, let last = recentShots.last, last.files > 0, saved.count >= last.files else { return }
        let median = shotAreas.sorted()[shotAreas.count / 2]
        guard Double(last.rect.area) < 0.35 * Double(median) else { return }
        do {
            try sink.dropLast(last.files)
            saved.removeLast(last.files)
            recentShots.removeLast()
            shotAreas.removeLast()
            log("dropped end screen (\(last.rect.width)×\(last.rect.height))")
        } catch {
            log("could not drop the end screen: \(error)")
        }
    }

    /// Play Books ends on a single back cover. If the last shot was split into two files,
    /// replaces them with one unsplit crop. On failure the split files stay and the failure is logged.
    private func mergeLastShot() {
        guard let last = recentShots.last, last.files == 2, saved.count >= 2 else { return }
        do {
            guard let crop = last.full.cropping(to: last.rect.cgRect) else { throw Stop.failed("crop failed \(last.rect)") }
            let url = try sink.replaceLast(2, with: crop)
            saved.removeLast(2)
            saved.append(url)
            recentShots[recentShots.count - 1].files = 1
            log("last page kept whole (back cover), \(saved.count) pages")
        } catch {
            log("could not merge the last page: \(error)")
        }
    }

    /// Crops the page out of `full`, segments it (`PageZone.segment`), optionally splits, saves. Stops at the cap.
    /// The first shot of a run (the front cover) is never split.
    /// Only the zone crop (+1 px) is converted to gray; segmentation runs in crop coordinates.
    private func savePage(_ full: CGImage) throws {
        guard saved.count < config.maxPages else { return }
        let area = zone.map { $0.scaled(by: d).clamped(width: full.width, height: full.height) }
            ?? PixelRect(x: 0, y: 0, width: full.width, height: full.height)
        // Gray crop 1 px wider than the area where the shot allows, so `segment` can tell a zone
        // edge inside the window (padded backdrop) from one on the window border.
        let grayArea = PixelRect(x: area.x - 1, y: area.y - 1, width: area.width + 2, height: area.height + 2)
            .clamped(width: full.width, height: full.height)
        // Empty area: same failure the zero-size trim result used to hit below.
        guard area.area > 0, let areaImage = full.cropping(to: grayArea.cgRect) else { throw Stop.failed("crop failed \(area)") }
        guard let gray = GrayImage(cgImage: areaImage) else { throw Stop.failed("cannot read full shot") }
        // Segmentation and gutter search run in crop (gray) coordinates; shifted to full-shot coordinates after.
        let rect = PageZone.segment(gray, zone: PixelRect(x: area.x - grayArea.x, y: area.y - grayArea.y,
                                                          width: area.width, height: area.height))
        let split = config.splitSpreads && !saved.isEmpty && SpreadSplitter.isSpread(rect)
        let local = split ? SpreadSplitter.split(rect, in: gray) : [rect]
        let shift = { (r: PixelRect) in PixelRect(x: r.x + grayArea.x, y: r.y + grayArea.y, width: r.width, height: r.height) }
        let rects = local.map(shift)
        recentShots = Array((recentShots + [(full, shift(rect), 0)]).suffix(2))
        shotAreas.append(rect.area)
        for r in rects {
            guard saved.count < config.maxPages else { return }
            guard r.area > 0, let crop = full.cropping(to: r.cgRect) else { throw Stop.failed("crop failed \(r)") }
            let url: URL
            do {
                url = try sink.save(crop)
            } catch {
                throw Stop.failed("save failed: \(error)")
            }
            saved.append(url)
            recentShots[recentShots.count - 1].files += 1
            onPageSaved?(saved.count, url)
            noChange = 0
            log("page \(saved.count) saved")
            onStatus?("Saved page \(saved.count)")
        }
    }

    // MARK: Helpers

    private func hash(_ preview: GrayImage) -> PageHash {
        if let zone { return PageHash(preview.cropped(zone)) }
        return PageHash(preview)
    }

    /// Preview downscaled to at most `thumbWidth` px wide, same aspect.
    private func thumb(_ preview: GrayImage) -> GrayImage {
        guard preview.width > thumbWidth else { return preview }
        return preview.resized(width: thumbWidth, height: max(preview.height * thumbWidth / preview.width, 1))
    }

    /// Wrap hash of a thumb: the current zone (scaled to thumb coordinates), segmented to
    /// the page, so a page shown at another spot inside the zone still matches.
    private func wrapHash(_ t: GrayImage) -> PageHash {
        guard let zone, previewWidth > 0, previewHeight > 0 else { return PageHash(t) }
        let x0 = zone.x * t.width / previewWidth, y0 = zone.y * t.height / previewHeight
        let x1 = (zone.maxX * t.width + previewWidth - 1) / previewWidth
        let y1 = (zone.maxY * t.height + previewHeight - 1) / previewHeight
        let z = PixelRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0).clamped(width: t.width, height: t.height)
        let page = PageZone.segment(t, zone: z)
        return PageHash(t.cropped(page.area > 0 ? page : z))
    }

    /// Wrap hashes of all saved shots for the current zone; recomputed after a zone change.
    private func currentWrapHashes() -> [PageHash] {
        if wrapHashZone != zone {
            wrapHashes = []
            wrapHashZone = zone
        }
        while wrapHashes.count < shotThumbs.count { wrapHashes.append(wrapHash(shotThumbs[wrapHashes.count])) }
        return wrapHashes
    }

    /// Near-blank page: `GrayImage.isNearBlank` on the page segmented out of the zone. Not a std or
    /// coverage test: a loading spinner, page number or edge shading pushes those over.
    /// Segmented because the zone is padded with backdrop and may hold a peeking next page.
    private func isBlank(_ preview: GrayImage, zone: PixelRect) -> Bool {
        let page = PageZone.segment(preview, zone: zone)
        return preview.isNearBlank(page, inkFraction: config.blankInkFraction, inkBoxFraction: config.blankInkBoxFraction)
    }

    private func checkCancel() throws {
        if isCancelled { throw Stop.cancelled }
    }

    private func sleep(_ s: Double) async throws {
        try checkCancel()
        if s > 0 { try await clock.sleep(s) }
        try checkCancel()
    }

    private func turn() throws {
        do {
            try turner.turnPage()
        } catch {
            throw Stop.failed("turn page: \(error)")
        }
        onStatus?("Turning page…")
    }

    private func captureFull() async throws -> CGImage {
        do {
            return try await capturer.captureFull()
        } catch {
            throw Stop.failed(String(describing: error))
        }
    }

    /// Preview as gray at exactly full / previewDownscale.
    private func capturePreviewGray() async throws -> GrayImage {
        let img: CGImage
        do {
            img = try await capturer.capturePreview()
        } catch {
            throw Stop.failed(String(describing: error))
        }
        try checkCancel()
        let w = previewWidth, h = previewHeight
        // Integer downscale straight from the context when it lands on the target size.
        if img.width >= w, img.width % w == 0, img.height / (img.width / w) == h,
           let g = GrayImage(cgImage: img, downscale: img.width / w), g.width == w, g.height == h {
            return g
        }
        guard let g = GrayImage(cgImage: img) else { throw Stop.failed("cannot read preview") }
        return g.resized(width: w, height: h)
    }
}
