import AppKit
import SwiftUI

/// Floating progress panel shown during a run. It never takes keyboard focus, so the key
/// presses keep going to the viewer; clicks on Stop still work.
@MainActor
final class CaptureHUDController {
    private let panel: HUDPanel
    static let size = NSSize(width: 360, height: 128)

    init(model: AppModel) {
        panel = HUDPanel(contentRect: NSRect(origin: .zero, size: Self.size),
                         styleMask: [.nonactivatingPanel, .borderless],
                         backing: .buffered, defer: false)
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        panel.appearance = NSAppearance(named: .darkAqua)   // HUD material is dark in both modes

        let effect = NSVisualEffectView(frame: NSRect(origin: .zero, size: Self.size))
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.maskImage = Self.roundedMask(radius: 14)
        let host = FirstMouseHostingView(rootView: CaptureHUDView(model: model).tint(Theme.accent))
        host.frame = effect.bounds
        host.autoresizingMask = [.width, .height]
        effect.addSubview(host)
        panel.contentView = effect
    }

    /// Shows the panel at a screen corner that doesn't cover `target` (global CG points).
    func show(avoiding target: CGRect) {
        panel.setFrameOrigin(Self.origin(avoiding: target, size: Self.size))
        panel.orderFrontRegardless()
    }

    func close() {
        panel.orderOut(nil)
    }

    /// First corner (bottom-right, bottom-left, top-right, top-left; target screen first, then
    /// the others) whose rect misses the target; else the corner with the least overlap.
    static func origin(avoiding cgTarget: CGRect, size: NSSize) -> NSPoint {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        // CG (top-left origin) → AppKit (bottom-left origin).
        let target = NSRect(x: cgTarget.minX, y: primaryHeight - cgTarget.maxY,
                            width: cgTarget.width, height: cgTarget.height)
        let screens = NSScreen.screens.sorted {
            $0.frame.intersection(target).area > $1.frame.intersection(target).area
        }
        let inset: CGFloat = 20
        var best: (overlap: CGFloat, origin: NSPoint)?
        for screen in screens {
            let v = screen.visibleFrame
            let corners = [
                NSPoint(x: v.maxX - size.width - inset, y: v.minY + inset),
                NSPoint(x: v.minX + inset, y: v.minY + inset),
                NSPoint(x: v.maxX - size.width - inset, y: v.maxY - size.height - inset),
                NSPoint(x: v.minX + inset, y: v.maxY - size.height - inset),
            ]
            for c in corners {
                let overlap = NSRect(origin: c, size: size).intersection(target).area
                if overlap == 0 { return c }
                if overlap < (best?.overlap ?? .infinity) { best = (overlap, c) }
            }
        }
        return best?.origin ?? .zero
    }

    private static func roundedMask(radius: CGFloat) -> NSImage {
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
}

private extension NSRect {
    var area: CGFloat { isNull ? 0 : width * height }
}

private final class HUDPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Buttons react to the first click even though the panel is never key.
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

struct CaptureHUDView: View {
    @Bindable var model: AppModel

    var body: some View {
        HStack(spacing: 14) {
            thumbnail
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Circle().fill(.red).frame(width: 8, height: 8)
                        .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
                    Text("Page \(model.progress.pageCount)")
                        .font(.system(size: 26, weight: .bold, design: .rounded).monospacedDigit())
                        .contentTransition(.numericText())
                        .animation(.snappy, value: model.progress.pageCount)
                }
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(elapsed(at: context.date))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Text(model.progress.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
            VStack(spacing: 6) {
                Button(role: .destructive) {
                    model.stop()
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                        .padding(.horizontal, 4)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.large)
                KeyCap(text: "ESC")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(width: CaptureHUDController.size.width, height: CaptureHUDController.size.height)
    }

    private var thumbnail: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(.white.opacity(0.08))
            if let img = model.lastPageThumb {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .padding(3)
                    .transition(.opacity)
                    .id(model.progress.lastPage)
            } else {
                Image(systemName: "doc.viewfinder")
                    .font(.system(size: 24, weight: .light))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 76, height: 100)
        .animation(.easeOut(duration: 0.2), value: model.progress.lastPage)
    }

    private func elapsed(at date: Date) -> String {
        let t = max(Int(date.timeIntervalSince(model.progress.startedAt)), 0)
        return String(format: "%d:%02d elapsed", t / 60, t % 60)
    }
}
