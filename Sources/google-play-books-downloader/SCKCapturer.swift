import CoreGraphics
import ScreenCaptureKit
import ScreenshoterCore

enum CapturerError: Error, CustomStringConvertible {
    case windowClosed, windowOffScreen, windowResized(from: CGSize, to: CGSize)

    var description: String {
        switch self {
        case .windowClosed: return "the picked window was closed"
        case .windowOffScreen: return "the picked window was minimized or moved to another Space"
        case .windowResized(let a, let b):
            return "the picked window was resized (\(Int(a.width))×\(Int(a.height)) → \(Int(b.width))×\(Int(b.height)) pt) — start a new capture"
        }
    }
}

/// Captures one window via ScreenCaptureKit, independent of what covers it.
///
/// Sizes are fixed at init from the window frame: full = frame × scale (rounded),
/// preview = `SessionConfig.previewSize` — the same helper CaptureSession uses, so the
/// preview it gets is exactly the size it expects. A window resized, closed or hidden mid-run
/// fails the next full capture (a move is fine: window capture follows the window).
final class SCKCapturer: WindowCapturer {
    let fullWidth: Int, fullHeight: Int
    let previewWidth: Int, previewHeight: Int
    private let filter: SCContentFilter
    private let fullConfig: SCStreamConfiguration
    private let previewConfig: SCStreamConfiguration
    private let windowID: CGWindowID
    /// Window size at init, global CG points (SCWindow.frame and the CG window list use the same space).
    private let startSize: CGSize

    init(window: SCWindow, scale: CGFloat, config: SessionConfig = SessionConfig()) {
        windowID = window.windowID
        startSize = window.frame.size
        filter = SCContentFilter(desktopIndependentWindow: window)
        fullWidth = max(Int((window.frame.width * scale).rounded()), 1)
        fullHeight = max(Int((window.frame.height * scale).rounded()), 1)
        (previewWidth, previewHeight) = config.previewSize(fullWidth: fullWidth, fullHeight: fullHeight)
        fullConfig = Self.streamConfig(fullWidth, fullHeight)
        previewConfig = Self.streamConfig(previewWidth, previewHeight)
    }

    /// Checks the window first (one CG window-list lookup); previews skip the check, they are
    /// polled every ~100 ms and a full shot follows every page.
    func captureFull() async throws -> CGImage {
        try checkWindow()
        return try await capture(fullConfig)
    }

    private func checkWindow() throws {
        switch WindowPicker.state(of: windowID) {
        case .gone: throw CapturerError.windowClosed
        case .offScreen: throw CapturerError.windowOffScreen
        case .onScreen(let frame):
            let tol: CGFloat = 2
            if abs(frame.width - startSize.width) > tol || abs(frame.height - startSize.height) > tol {
                throw CapturerError.windowResized(from: startSize, to: frame.size)
            }
        }
    }

    func capturePreview() async throws -> CGImage {
        try await capture(previewConfig)
    }

    /// Retry delays after a failed capture. macOS 26 sometimes fails a capture right after
    /// start with SCStreamErrorDomain -3811 ("Failed to start stream due to audio/video
    /// capture failure"); a short wait fixes it.
    private static let retryDelays: [Double] = [0.3, 0.8]

    private func capture(_ configuration: SCStreamConfiguration) async throws -> CGImage {
        try await Self.capture(filter: filter, configuration: configuration, logRetries: true)
    }

    /// One small shot of `window` for the setup preview, at most `maxWidth` pixels wide
    /// (aspect kept). Same stream config and retry as a run; retries are not logged, since
    /// the setup screen calls this every 2 s.
    static func snapshot(window: SCWindow, maxWidth: Int) async throws -> CGImage {
        let w = max(window.frame.width, 1), h = max(window.frame.height, 1)
        let scale = min(CGFloat(max(maxWidth, 1)) / w, 2)
        let config = streamConfig(max(Int((w * scale).rounded()), 1), max(Int((h * scale).rounded()), 1))
        return try await capture(filter: SCContentFilter(desktopIndependentWindow: window),
                                 configuration: config, logRetries: false)
    }

    private static func capture(filter: SCContentFilter, configuration: SCStreamConfiguration,
                                logRetries: Bool) async throws -> CGImage {
        var attempt = 0
        while true {
            do {
                return try await SCScreenshotManager.captureImage(contentFilter: filter,
                                                                  configuration: configuration)
            } catch {
                // Cancellation is not a capture failure: do not retry it.
                guard attempt < retryDelays.count, !Task.isCancelled else { throw error }
                let delay = retryDelays[attempt]
                attempt += 1
                if logRetries {
                    Log.write("capture failed (\(error)), retry \(attempt)/\(retryDelays.count) in \(delay)s")
                }
                try await Task.sleep(for: .seconds(max(delay, 0)))
            }
        }
    }

    private static func streamConfig(_ w: Int, _ h: Int) -> SCStreamConfiguration {
        let c = SCStreamConfiguration()
        c.width = w
        c.height = h
        c.showsCursor = false
        c.ignoreShadowsSingleWindow = true   // no drop-shadow margin around the window
        return c
    }
}
