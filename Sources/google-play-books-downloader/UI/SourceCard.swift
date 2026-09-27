import SwiftUI

/// The viewer window to capture: empty drop zone, or the picked window with a live preview.
struct SourceCard: View {
    @Bindable var model: AppModel
    @State private var showList = false

    var body: some View {
        Card(tint: model.source != nil && model.sourceHealth == .gone ? .red : nil) {
            VStack(alignment: .leading, spacing: 14) {
                CardHeader(title: "Google Play Books window", symbol: "macwindow")
                if let source = model.source {
                    picked(source)
                } else {
                    empty
                }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.source?.id)
        .animation(.easeInOut(duration: 0.2), value: model.sourceHealth)
    }

    // MARK: Empty

    private var empty: some View {
        VStack(spacing: 12) {
            Image(systemName: "macwindow.on.rectangle")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(Theme.accent)
            VStack(spacing: 4) {
                Text("Choose the Google Play Books window")
                    .font(.title3.weight(.semibold))
                Text("Open the book in Google Play Books (browser), two-page view, at the cover.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            HStack(spacing: 10) {
                Button {
                    model.pickByClick()
                } label: {
                    Label("Click a window…", systemImage: "cursorarrow.click")
                }
                .buttonStyle(.borderedProminent)
                listButton(title: "Choose from list", symbol: "list.bullet")
            }
            .disabled(model.permissions.screen != .granted)
            if model.permissions.screen != .granted {
                Label("Allow Screen Recording first to choose a window.", systemImage: "lock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
        .padding(.horizontal, 12)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                .foregroundStyle(Theme.accent.opacity(0.45))
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.accent.opacity(0.04)))
        }
    }

    private func listButton(title: String, symbol: String) -> some View {
        Button {
            showList = true
        } label: {
            Label(title, systemImage: symbol)
        }
        .popover(isPresented: $showList, arrowEdge: .bottom) {
            WindowListView(model: model) { candidate in
                showList = false
                model.pick(from: candidate)
            }
        }
    }

    // MARK: Picked

    private func picked(_ s: SourceWindow) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            preview(s)
            HStack(alignment: .top, spacing: 12) {
                AppIcon(image: s.appIcon, size: 40)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(s.appName)
                            .font(.body.weight(.bold))
                        if s.isPlayBooks { PlayBooksBadge() }
                    }
                    Text(s.title.isEmpty ? "Untitled window" : s.title)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .help(s.title)
                    Text("\(Int(s.frame.width.rounded())) × \(Int(s.frame.height.rounded())) pt")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 8)
                HStack(spacing: 6) {
                    Button("Show") { model.showSource() }
                        .help("Bring the window to the front")
                        .disabled(model.sourceHealth == .gone)
                    listButton(title: "Change", symbol: "arrow.triangle.2.circlepath")
                        .labelStyle(.titleOnly)
                        .help("Choose another window from the list")
                    Button { model.pickByClick() } label: { Image(systemName: "cursorarrow.click") }
                        .help("Click a different window")
                }
                .fixedSize()
            }
            healthBanner
        }
    }

    /// Live 16:10 thumbnail; app icon + hint without Screen Recording; red when gone.
    private func preview(_ s: SourceWindow) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .underPageBackgroundColor))
            if model.sourceHealth == .gone {
                VStack(spacing: 8) {
                    Image(systemName: "xmark.rectangle")
                        .font(.system(size: 30, weight: .light))
                    Text("Window closed")
                        .font(.headline)
                }
                .foregroundStyle(.red)
            } else if let thumb = model.sourceThumbnail, model.permissions.screen == .granted {
                Image(decorative: thumb, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
                    .padding(10)
                    .transition(.opacity)
            } else if model.permissions.screen != .granted {
                VStack(spacing: 10) {
                    AppIcon(image: s.appIcon, size: 56)
                    Text("Allow Screen Recording to see a preview")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .aspectRatio(16 / 10, contentMode: .fit)
        .frame(maxHeight: 220)
        .frame(maxWidth: .infinity)
        .overlay(alignment: .topTrailing) {
            if model.sourceHealth == .ok, model.sourceThumbnail != nil, model.permissions.screen == .granted {
                Label("Live", systemImage: "dot.radiowaves.left.and.right")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(.ultraThinMaterial))
                    .padding(8)
                    .help("Refreshed every 2 seconds")
            }
        }
    }

    @ViewBuilder
    private var healthBanner: some View {
        switch model.sourceHealth {
        case .ok:
            EmptyView()
        case .gone:
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                Text("Window closed — choose again.")
                    .font(.callout.weight(.medium))
                Spacer()
                Button("Choose again") { model.pickByClick() }
            }
            .foregroundStyle(.red)
        case .offScreen:
            HStack(spacing: 8) {
                Image(systemName: "eye.slash")
                Text("The window is minimized or on another Space.")
                    .font(.callout)
                Spacer()
                Button("Show") { model.showSource() }
            }
            .foregroundStyle(.orange)
        }
    }
}

/// Small "Play Books" capsule for windows that show Google Play Books.
struct PlayBooksBadge: View {
    var body: some View {
        Label("Play Books", systemImage: "book.fill")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, 6)
            .padding(.vertical, 1.5)
            .background(Capsule().fill(Theme.accent.opacity(0.14)))
            .fixedSize()
    }
}

/// App icon with a neutral fallback.
struct AppIcon: View {
    let image: NSImage?
    let size: CGFloat
    var body: some View {
        if let image {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
        } else {
            Image(systemName: "app.dashed")
                .font(.system(size: size * 0.7, weight: .light))
                .foregroundStyle(.secondary)
                .frame(width: size, height: size)
        }
    }
}

/// Popover list of on-screen windows: app icon, app name, window title.
private struct WindowListView: View {
    @Bindable var model: AppModel
    let onPick: (SourceWindow) -> Void
    @State private var loading = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Windows on screen")
                .font(.headline)
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 8)
            Divider()
            content
        }
        .frame(width: 400)
        .task {
            loading = true
            await model.loadWindowList()
            loading = false
        }
    }

    @ViewBuilder
    private var content: some View {
        if loading && model.windowList.isEmpty {
            ProgressView().frame(maxWidth: .infinity, minHeight: 120)
        } else if let error = model.windowListError {
            Label(error, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 120)
                .padding(.horizontal, 14)
        } else if model.windowList.isEmpty {
            Text("No other windows on screen.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 120)
        } else {
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(model.windowList, id: \.id) { w in
                        WindowRow(window: w, selected: w.id == model.source?.id) { onPick(w) }
                    }
                }
                .padding(6)
            }
            .frame(maxHeight: 360)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct WindowRow: View {
    let window: SourceWindow
    let selected: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                AppIcon(image: window.appIcon, size: 28)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(window.appName).font(.callout.weight(.semibold))
                        if window.isPlayBooks { PlayBooksBadge() }
                    }
                    Text(window.title.isEmpty ? "Untitled window" : window.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 4)
                if selected {
                    Image(systemName: "checkmark").foregroundStyle(Theme.accent)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 6).fill(hover ? Theme.accent.opacity(0.12) : .clear))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}
