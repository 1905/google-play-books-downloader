import AppKit
import CoreGraphics
import ScreenCaptureKit

extension NSScreen {
    /// AppKit global rect (bottom-left origin of the primary screen) → CG global rect
    /// (top-left origin of the primary screen, as CGWindowList bounds and SCWindow.frame use).
    static func cgRect(fromAppKit r: CGRect) -> CGRect {
        let primaryHeight = screens.first?.frame.height ?? 0
        return CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }
}

/// Finds the target window, by title substring (CLI) or by one click (GUI).
enum WindowPicker {
    /// First on-screen, normal-layer window (front to back) whose title contains `titleContains`
    /// (case-insensitive); else the first whose owning app name contains it.
    static func find(titleContains s: String) async throws -> SCWindow? {
        let own = ProcessInfo.processInfo.processIdentifier
        let order = frontToBackOrder()
        let candidates = try await onScreenWindows()
            .filter { $0.windowLayer == 0 && $0.isOnScreen && $0.owningApplication?.processID != own
                && $0.frame.width >= 100 && $0.frame.height >= 100 }
            .sorted { (order[$0.windowID] ?? .max) < (order[$1.windowID] ?? .max) }
        if let w = candidates.first(where: { ($0.title ?? "").localizedCaseInsensitiveContains(s) }) {
            return w
        }
        return candidates.first { ($0.owningApplication?.applicationName ?? "").localizedCaseInsensitiveContains(s) }
    }

    /// On-screen normal windows of other apps for the "Choose from list" menu, front to back.
    /// Skips tiny windows (< 120 × 80 pt) such as status items and palettes.
    static func listWindows() async throws -> [SCWindow] {
        let own = ProcessInfo.processInfo.processIdentifier
        let order = frontToBackOrder()
        return try await onScreenWindows()
            .filter { $0.windowLayer == 0 && $0.isOnScreen && $0.owningApplication != nil
                && $0.owningApplication?.processID != own
                && $0.frame.width >= 120 && $0.frame.height >= 80 }
            .sorted { (order[$0.windowID] ?? .max) < (order[$1.windowID] ?? .max) }
    }

    enum WindowState: Equatable {
        /// On screen; `frame` in global CG points (top-left origin).
        case onScreen(frame: CGRect)
        /// Exists, but minimized, hidden or on another Space.
        case offScreen
        case gone
    }

    /// State of the window with this id from the CG window list. Needs no Screen Recording.
    static func state(of id: CGWindowID) -> WindowState {
        guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]],
              let info = list.first(where: { ($0[kCGWindowNumber as String] as? CGWindowID) == id })
        else { return .gone }
        guard (info[kCGWindowIsOnscreen as String] as? Bool) == true,
              let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
        else { return .offScreen }
        return .onScreen(frame: bounds)
    }

    /// Shows a click overlay on every screen. Calls `completion` on the main thread with the
    /// clicked window, or nil on ESC / no window under the click. Main thread only.
    static func pick(completion: @escaping (SCWindow?) -> Void) {
        guard current == nil else { return }
        current = PickerOverlay { windowID in
            current = nil
            guard let windowID else { completion(nil); return }
            Task { @MainActor in
                completion(try? await window(id: windowID))
            }
        }
    }

    /// Fresh on-screen SCWindow with this id, nil if it is gone.
    static func window(id: CGWindowID) async throws -> SCWindow? {
        try await onScreenWindows().first { $0.windowID == id }
    }

    private static var current: PickerOverlay?

    private static func onScreenWindows() async throws -> [SCWindow] {
        try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true).windows
    }

    /// CG window list, on-screen only, no desktop elements, front to back.
    private static func onScreenWindowInfo() -> [[String: Any]] {
        CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
    }

    /// windowID → z-order index (0 = frontmost) from the CG window list.
    private static func frontToBackOrder() -> [CGWindowID: Int] {
        var order: [CGWindowID: Int] = [:]
        for (i, info) in onScreenWindowInfo().enumerated() {
            if let id = info[kCGWindowNumber as String] as? CGWindowID { order[id] = i }
        }
        return order
    }

    /// Topmost layer-0 window of another process whose bounds contain `point`
    /// (global CG coordinates: top-left origin of the primary screen, points).
    static func windowID(at point: CGPoint) -> CGWindowID? {
        let own = ProcessInfo.processInfo.processIdentifier
        for info in onScreenWindowInfo() {   // front to back
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != own,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                  bounds.contains(point),
                  let id = info[kCGWindowNumber as String] as? CGWindowID
            else { continue }
            return id
        }
        return nil
    }
}

/// Transparent borderless window per screen; click picks, ESC cancels.
private final class PickerOverlay {
    private var windows: [NSWindow] = []
    private var keyMonitor: Any?
    private var done: ((CGWindowID?) -> Void)?

    init(done: @escaping (CGWindowID?) -> Void) {
        self.done = done
        for screen in NSScreen.screens {
            let w = OverlayWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            w.level = .screenSaver
            w.isOpaque = false
            w.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.08)
            w.ignoresMouseEvents = false
            w.hasShadow = false
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            let view = OverlayView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.onClick = { [weak self] in self?.clicked() }
            w.contentView = view
            w.setFrame(screen.frame, display: false)
            w.orderFrontRegardless()
            windows.append(w)
        }
        windows.first?.makeKey()
        NSApp.activate()
        NSCursor.crosshair.push()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }   // ESC
            self?.finish(nil)
            return nil
        }
    }

    private func clicked() {
        // NSEvent.mouseLocation is AppKit global; CGWindowList bounds are CG global.
        let p = NSScreen.cgRect(fromAppKit: CGRect(origin: NSEvent.mouseLocation, size: .zero)).origin
        finish(WindowPicker.windowID(at: p))
    }

    private func finish(_ id: CGWindowID?) {
        guard let done else { return }
        self.done = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        NSCursor.pop()
        windows.forEach { $0.orderOut(nil) }
        windows = []
        done(id)
    }
}

private final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

private final class OverlayView: NSView {
    var onClick: (() -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onClick?() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }
}
