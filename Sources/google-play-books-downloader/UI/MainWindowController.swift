import AppKit
import SwiftUI

/// Colors and metrics shared by every screen.
enum Theme {
    /// Teal from the app icon.
    static let accent = Color(red: 0.05, green: 0.55, blue: 0.65)
    static let padding: CGFloat = 20
    static let cardRadius: CGFloat = 12

    /// Two columns; fits a 1440 × 900 screen with menu bar and Dock.
    static let setupSize = NSSize(width: 940, height: 620)
    static let setupMinSize = NSSize(width: 820, height: 480)
    static let reviewSize = NSSize(width: 900, height: 700)
    static let reviewMinSize = NSSize(width: 620, height: 460)
}

/// Rounded grouped card: control background, hairline border, soft shadow. Works in light and dark.
struct Card<Content: View>: View {
    var tint: Color?
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .overlay {
                        if let tint {
                            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous).fill(tint.opacity(0.07))
                        }
                    }
                    .shadow(color: .black.opacity(0.06), radius: 3, y: 1)
            }
            .overlay {
                RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                    .strokeBorder(tint?.opacity(0.55) ?? Color(nsColor: .separatorColor), lineWidth: tint == nil ? 0.5 : 1)
            }
    }
}

/// Small uppercase-free section title with an SF Symbol, used above each card's content.
struct CardHeader: View {
    let title: String
    let symbol: String
    var body: some View {
        Label(title, systemImage: symbol)
            .font(.headline)
            .foregroundStyle(.primary)
    }
}

/// Status capsule: "Granted", "Needed", "Relaunch needed".
struct StatusPill: View {
    let text: String
    let color: Color
    var symbol: String?

    var body: some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol).imageScale(.small) }
            Text(text)
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .foregroundStyle(color)
        .background(Capsule().fill(color.opacity(0.14)))
        .fixedSize()
    }
}

/// Keycap-style hint, e.g. "ESC".
struct KeyCap: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold).monospaced())
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(RoundedRectangle(cornerRadius: 4).fill(.quaternary))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.tertiary, lineWidth: 0.5))
    }
}

/// Root view: switches between the setup and review stages.
struct RootView: View {
    @Bindable var model: AppModel

    var body: some View {
        ZStack {
            switch model.stage {
            case .setup, .capturing:
                SetupView(model: model)
                    .transition(.opacity)
            case .review:
                ReviewView(model: model)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.stage)
        .tint(Theme.accent)
        .background(Color(nsColor: .windowBackgroundColor).ignoresSafeArea())
        .alert(model.alert?.title ?? "", isPresented: Binding(
            get: { model.alert != nil },
            set: { if !$0 { model.alert = nil } }
        ), presenting: model.alert) { _ in
            Button("OK", role: .cancel) {}
        } message: { item in
            Text(item.message)
        }
    }
}

/// The one app window. Its content follows `AppModel.stage`; it is hidden while capturing.
@MainActor
final class MainWindowController: NSObject, NSWindowDelegate {
    let window: NSWindow
    private let model: AppModel
    /// Called when the user closes the window.
    var onClose: (() -> Void)?

    init(model: AppModel) {
        self.model = model
        window = NSWindow(contentRect: NSRect(origin: .zero, size: Theme.setupSize),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        super.init()
        window.title = AppInfo.name
        // Transparent titlebar without full-size content: it takes the window color, and the
        // content (incl. scrolled content) always starts below it.
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.minSize = Theme.setupMinSize
        window.delegate = self
        let host = NSHostingView(rootView: RootView(model: model))
        host.sizingOptions = []   // the controller sizes the window per stage
        window.contentView = host
        window.center()
        model.window = window
        model.onStageChange = { [weak self] stage in self?.apply(stage) }
    }

    /// Shows the window in front, also when another app (the viewer) is active.
    func show() {
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    private func apply(_ stage: AppModel.Stage) {
        switch stage {
        case .capturing:
            window.orderOut(nil)
        case .setup:
            resize(to: Theme.setupSize, min: Theme.setupMinSize)
            show()
        case .review:
            resize(to: Theme.reviewSize, min: Theme.reviewMinSize)
            show()
        }
    }

    /// Resizes around the current center, kept inside the visible screen area.
    private func resize(to size: NSSize, min: NSSize) {
        window.minSize = min
        let visible = (window.screen ?? NSScreen.main)?.visibleFrame ?? NSRect(origin: .zero, size: size)
        let w = Swift.min(size.width, visible.width), h = Swift.min(size.height, visible.height)
        let old = window.frame
        var frame = NSRect(x: old.midX - w / 2, y: old.maxY - h, width: w, height: h)
        frame.origin.x = Swift.max(visible.minX, Swift.min(frame.minX, visible.maxX - w))
        frame.origin.y = Swift.max(visible.minY, Swift.min(frame.minY, visible.maxY - h))
        window.setFrame(frame, display: true, animate: window.isVisible)
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }
}
