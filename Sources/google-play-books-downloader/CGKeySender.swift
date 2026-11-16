import AppKit
import ApplicationServices
import CoreGraphics
import ScreenshoterCore

enum KeySenderError: CaptureFailureKind, CustomStringConvertible {
    case appGone(pid_t), eventFailed, accessibilityRevoked, notFrontmost(String)

    var failureKind: FailureKind {
        switch self {
        case .appGone: return .appGone
        case .eventFailed: return .other
        case .accessibilityRevoked: return .accessibilityRevoked
        case .notFrontmost: return .notFrontmost
        }
    }

    var description: String {
        switch self {
        case .appGone(let pid): return "target app (pid \(pid)) is gone"
        case .eventFailed: return "cannot create key event"
        case .accessibilityRevoked: return "Accessibility permission is off — the app cannot press keys"
        case .notFrontmost(let app):
            return "the picked window (\(app)) could not be brought to the front; keys would go to another app"
        }
    }
}

/// Brings the picked window to front and posts the next-page key via CGEvent.
///
/// Keys go to the app's key window, so activating the app alone is not enough when it has
/// several windows. Before each key, the picked window is raised and made main via
/// Accessibility, but only when the app is inactive or another of its windows has focus.
final class CGKeySender: PageTurner {
    private let pid: pid_t
    private let key: NextKey
    private let windowTitle: String?
    /// Global points, top-left origin (same space as AXPosition/AXSize).
    private let windowFrame: CGRect
    private var target: AXUIElement?
    private var warnedNoMatch = false

    init(pid: pid_t, key: NextKey, windowTitle: String?, windowFrame: CGRect) {
        self.pid = pid
        self.key = key
        self.windowTitle = windowTitle
        self.windowFrame = windowFrame
    }

    /// Fails instead of posting the key when Accessibility is off or the target app is not
    /// frontmost after one retry: a key posted then lands in whatever app is in front.
    func turnPage() throws {
        guard AXIsProcessTrusted() else { throw KeySenderError.accessibilityRevoked }
        try bringToFront()
        if !isFrontmost() {
            Log.write("target app not frontmost after raise, retrying")
            try bringToFront()
            if !isFrontmost() {
                Thread.sleep(forTimeInterval: 0.2)
                guard isFrontmost() else {
                    let name = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "pid \(pid)"
                    throw KeySenderError.notFrontmost(name)
                }
            }
        }
        try postKey()
    }

    /// The target app is the frontmost app. Read on the main thread: NSWorkspace and
    /// NSRunningApplication update these values on the main run loop only, so a read from
    /// the capture thread could be stale.
    private func isFrontmost() -> Bool {
        let pid = self.pid
        return onMain { NSWorkspace.shared.frontmostApplication?.processIdentifier == pid }
    }

    /// Raises the picked window (Accessibility) and activates its app. Without Accessibility
    /// only the app activation works. Sleeps 50 ms after a change so the next key lands.
    func bringToFront() throws {
        guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else {
            throw KeySenderError.appGone(pid)
        }
        let axApp = AXUIElementCreateApplication(pid)
        if target == nil {
            target = findTargetWindow(in: axApp)
            if target == nil && !warnedNoMatch {
                warnedNoMatch = true
                Log.write("warning: picked window not found via Accessibility, keys go to the app's key window")
            }
        }
        let front = isFrontmost()
        var changed = false
        if let win = target, !front || !isFocused(win, in: axApp) {
            AXUIElementPerformAction(win, kAXRaiseAction as CFString)
            AXUIElementSetAttributeValue(win, kAXMainAttribute as CFString, kCFBooleanTrue)
            changed = true
        }
        if !front {
            onMain {
                NSApp.yieldActivation(to: app)   // macOS 14 cooperative activation
                app.activate()
            }
            // Cooperative activation is sometimes refused when a run starts from our own window
            // (seen live: every Page Down went nowhere). The Accessibility frontmost flag is not.
            AXUIElementSetAttributeValue(axApp, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
            changed = true
        }
        if changed {
            // Wait until the app really is in front (max 0.5 s) so the key does not land elsewhere.
            for _ in 0..<10 where !isFrontmost() { Thread.sleep(forTimeInterval: 0.05) }
            Thread.sleep(forTimeInterval: 0.05)
        }
    }

    private func postKey() throws {
        let src = CGEventSource(stateID: .hidSystemState)
        guard let down = CGEvent(keyboardEventSource: src, virtualKey: key.keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: key.keyCode, keyDown: false)
        else { throw KeySenderError.eventFailed }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    /// AX window whose position and size match `windowFrame` (±2 pt); among several (e.g. two
    /// maximised windows of one browser) the one whose title is `windowTitle`, else the first.
    /// No frame match: the first title match.
    private func findTargetWindow(in axApp: AXUIElement) -> AXUIElement? {
        guard let windows = Self.attribute(axApp, kAXWindowsAttribute) as? [AXUIElement] else { return nil }
        let tol: CGFloat = 2
        let frameMatches = windows.filter { win in
            guard let pos = Self.point(Self.attribute(win, kAXPositionAttribute)),
                  let size = Self.size(Self.attribute(win, kAXSizeAttribute)) else { return false }
            return abs(pos.x - windowFrame.minX) <= tol && abs(pos.y - windowFrame.minY) <= tol
                && abs(size.width - windowFrame.width) <= tol && abs(size.height - windowFrame.height) <= tol
        }
        let title = windowTitle ?? ""
        let hasTitle: (AXUIElement) -> Bool = { !title.isEmpty && (Self.attribute($0, kAXTitleAttribute) as? String) == title }
        if let win = frameMatches.first(where: hasTitle) ?? frameMatches.first { return win }
        return windows.first(where: hasTitle)
    }

    private func isFocused(_ win: AXUIElement, in axApp: AXUIElement) -> Bool {
        guard let focused = Self.attribute(axApp, kAXFocusedWindowAttribute),
              CFGetTypeID(focused) == AXUIElementGetTypeID() else { return false }
        return CFEqual(focused, win)
    }

    private static func attribute(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, name as CFString, &value) == .success ? value : nil
    }

    private static func point(_ v: CFTypeRef?) -> CGPoint? {
        guard let v, CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var p = CGPoint.zero
        return AXValueGetValue(v as! AXValue, .cgPoint, &p) ? p : nil
    }

    private static func size(_ v: CFTypeRef?) -> CGSize? {
        guard let v, CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var s = CGSize.zero
        return AXValueGetValue(v as! AXValue, .cgSize, &s) ? s : nil
    }

    private func onMain<T>(_ body: () -> T) -> T {
        if Thread.isMainThread { return body() } else { return DispatchQueue.main.sync(execute: body) }
    }
}

enum Permissions {
    /// Screen Recording. `request` shows the system prompt once (the grant needs a relaunch).
    static func screenRecording(request: Bool) -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        return request ? CGRequestScreenCaptureAccess() : false
    }

    /// Accessibility (needed to post key events). `prompt` opens the system dialog.
    static func accessibility(prompt: Bool) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: prompt] as CFDictionary)
    }
}
