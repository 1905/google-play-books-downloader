import ScreenshoterCore
import SwiftUI

/// Stage 3: check the pages, remove bad ones, save the PDF, clean the cache.
struct ReviewView: View {
    @Bindable var model: AppModel
    @State private var viewer: PageRef?

    struct PageRef: Identifiable, Equatable {
        let url: URL
        var id: URL { url }
    }

    var body: some View {
        if let review = model.review {
            VStack(spacing: 0) {
                header(review)
                    .padding(.horizontal, Theme.padding)
                    .padding(.top, 6)
                    .padding(.bottom, 12)
                toolbar(review)
                    .padding(.horizontal, Theme.padding)
                    .padding(.bottom, 12)
                banner(review)
                Divider()
                if review.pages.isEmpty {
                    emptyState(review)
                } else {
                    grid(review)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: review.savedPDF)
            .animation(.easeInOut(duration: 0.2), value: review.cacheTrashed)
            .sheet(item: $viewer) { ref in
                PageViewer(model: model, start: ref.url)
            }
        }
    }

    // MARK: Header

    private func header(_ r: ReviewState) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: reasonSymbol(r.reason))
                .font(.system(size: 26))
                .foregroundStyle(reasonColor(r.reason))
            VStack(alignment: .leading, spacing: 2) {
                Text("\(r.pages.count) \(r.pages.count == 1 ? "page" : "pages")")
                    .font(.title2.weight(.bold))
                    .contentTransition(.numericText())
                Text(subtitle(r))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .help(r.reason.words)
            }
            Spacer()
            let incomplete = model.incompletePages.count
            if incomplete > 0 && !r.locked {
                Button {
                    model.selectIncomplete()
                } label: {
                    Label("\(incomplete) \(incomplete == 1 ? "page looks" : "pages look") incomplete",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Color.orange.opacity(0.14)))
                        .overlay(Capsule().strokeBorder(Color.orange.opacity(0.4), lineWidth: 0.5))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("Much shorter than the other pages. Click to select them, then press ⌫ to remove.")
                .transition(.opacity)
            }
            Text(r.runName)
                .font(.caption.monospaced())
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(r.cacheDir.path)
        }
    }

    private func subtitle(_ r: ReviewState) -> String {
        var parts = [r.reason.words, Settings.durationWords(r.duration)]
        let removed = r.captureNumbers.count - r.pages.count
        if removed > 0 { parts.append("\(removed) removed") }
        return parts.joined(separator: " · ")
    }

    private func reasonSymbol(_ reason: StopReason) -> String {
        switch reason {
        case .endOfDocument: return "checkmark.circle.fill"
        case .capReached: return "flag.checkered.circle.fill"
        case .cancelled: return "stop.circle.fill"
        case .captureFailed: return "exclamationmark.triangle.fill"
        }
    }

    private func reasonColor(_ reason: StopReason) -> Color {
        switch reason {
        case .endOfDocument: return .green
        case .capReached: return .orange
        case .cancelled: return .secondary
        case .captureFailed: return .red
        }
    }

    // MARK: Toolbar

    private func toolbar(_ r: ReviewState) -> some View {
        HStack(spacing: 8) {
            Button {
                model.removeSelected()
            } label: {
                Label(r.selection.isEmpty ? "Remove" : "Remove \(r.selection.count)", systemImage: "trash")
            }
            .keyboardShortcut(.delete, modifiers: [])
            .disabled(r.selection.isEmpty || r.locked)
            .help("Remove the selected pages from the PDF (⌫)")

            Text(r.selection.isEmpty ? "Click to select · ⌘/⇧-click for more · double-click to enlarge" : "\(r.selection.count) selected")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.leading, 4)

            Spacer(minLength: 8)

            Button("Delete cached images") { model.trashCache() }
                .disabled(r.savedPDF == nil || r.locked)
                .help(r.savedPDF == nil ? "Save the PDF first" : "Move the captured images to the Trash")
            if !model.headless {
                Button {
                    model.newCapture()
                } label: {
                    Label("New capture", systemImage: "plus")
                }
                .disabled(r.saving)
            }
            Button {
                model.savePDF()
            } label: {
                if r.saving {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Saving…")
                    }
                } else {
                    Label("Save PDF…", systemImage: "square.and.arrow.down")
                }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut("s", modifiers: .command)
            .disabled(r.pages.isEmpty || r.locked)
        }
        .controlSize(.large)
    }

    // MARK: Banner

    @ViewBuilder
    private func banner(_ r: ReviewState) -> some View {
        if let pdf = r.savedPDF {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Saved \(r.savedCount) \(r.savedCount == 1 ? "page" : "pages")"
                         + (r.savedBytes.map { " · " + ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? ""))
                        .font(.callout.weight(.semibold))
                    Text(r.cacheTrashed ? "Cached images moved to the Trash." : (pdf.path as NSString).abbreviatingWithTildeInPath)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Button("Show in Finder") { model.showSavedInFinder() }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.green.opacity(0.12)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.green.opacity(0.35), lineWidth: 0.5))
            .padding(.horizontal, Theme.padding)
            .padding(.bottom, 12)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    // MARK: Grid

    private func grid(_ r: ReviewState) -> some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 200), spacing: 16)], spacing: 18) {
                ForEach(r.pages, id: \.self) { url in
                    PageCell(url: url,
                             number: r.captureNumbers[url] ?? 0,
                             selected: r.selection.contains(url))
                        .onTapGesture(count: 2) {
                            if !r.cacheTrashed { viewer = PageRef(url: url) }
                        }
                        .simultaneousGesture(TapGesture().onEnded {
                            let flags = NSEvent.modifierFlags
                            model.click(url, command: flags.contains(.command), shift: flags.contains(.shift))
                        })
                        .transition(.scale(scale: 0.8).combined(with: .opacity))
                }
            }
            .padding(Theme.padding)
            .animation(.easeInOut(duration: 0.2), value: r.pages)
        }
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    private func emptyState(_ r: ReviewState) -> some View {
        ContentUnavailableView {
            Label("No pages captured", systemImage: "doc.questionmark")
        } description: {
            Text(r.captureNumbers.isEmpty
                 ? "The run ended before the first page was saved: \(r.reason.words)."
                 : "You removed every page.")
        } actions: {
            if !model.headless {
                Button("New capture") { model.newCapture() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .underPageBackgroundColor))
    }
}

/// One thumbnail with its capture-number badge and selection ring.
private struct PageCell: View {
    let url: URL
    let number: Int
    let selected: Bool
    @State private var hover = false

    var body: some View {
        VStack(spacing: 6) {
            ThumbnailImage(url: url, maxPixel: 400)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                .shadow(color: .black.opacity(hover ? 0.3 : 0.18), radius: hover ? 6 : 3, y: 1)
                .frame(height: 190)
                .frame(maxWidth: .infinity)
            Text("\(number)")
                .font(.caption.weight(.semibold).monospacedDigit())
                .padding(.horizontal, 7)
                .padding(.vertical, 1)
                .foregroundStyle(selected ? Color.white : Color.secondary)
                .background(Capsule().fill(selected ? Theme.accent : Color.clear))
        }
        .padding(8)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(selected ? Theme.accent.opacity(0.16) : (hover ? Color.primary.opacity(0.05) : .clear))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Theme.accent, lineWidth: selected ? 2.5 : 0)
        }
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.12), value: selected)
        .help("Capture \(number)")
    }
}

/// Large view of one page with ←/→ navigation. Esc closes.
private struct PageViewer: View {
    @Bindable var model: AppModel
    @State private var current: URL
    @State private var image: NSImage?
    @Environment(\.dismiss) private var dismiss

    init(model: AppModel, start: URL) {
        self.model = model
        _current = State(initialValue: start)
    }

    private var pages: [URL] { model.review?.pages ?? [] }
    private var index: Int { pages.firstIndex(of: current) ?? 0 }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button { step(-1) } label: { Image(systemName: "chevron.left") }
                    .keyboardShortcut(.leftArrow, modifiers: [])
                    .disabled(index == 0)
                Button { step(1) } label: { Image(systemName: "chevron.right") }
                    .keyboardShortcut(.rightArrow, modifiers: [])
                    .disabled(index >= pages.count - 1)
                Text("Page \(index + 1) of \(pages.count)")
                    .font(.headline.monospacedDigit())
                Text("capture \(model.review?.captureNumbers[current] ?? 0)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(12)
            Divider()
            ZStack {
                Color(nsColor: .underPageBackgroundColor)
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .shadow(color: .black.opacity(0.25), radius: 8, y: 2)
                        .padding(16)
                } else {
                    ProgressView()
                }
            }
        }
        .frame(width: sheetSize.width, height: sheetSize.height)
        .task(id: current) {
            let url = current
            image = Thumbnails.cached(url, maxPixel: 400)   // blurry stand-in while the full image loads
            let full = await Thumbnails.fullImage(for: url)
            // A newer page (or a closed sheet) cancelled this load: don't overwrite its image.
            if let full, !Task.isCancelled, url == current { image = full }
        }
    }

    private var sheetSize: CGSize {
        let w = model.window?.frame.size ?? CGSize(width: 900, height: 700)
        return CGSize(width: max(w.width - 60, 520), height: max(w.height - 80, 420))
    }

    private func step(_ d: Int) {
        let i = index + d
        guard pages.indices.contains(i) else { return }
        current = pages[i]
    }
}
