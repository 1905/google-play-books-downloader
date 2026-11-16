import ScreenshoterCore
import SwiftUI

/// Human headline for how a run ended: title, one direction line, the raw core message.
struct RunOutcome {
    let title: String
    /// What to do about it; nil when the run ended normally.
    let direction: String?
    let symbol: String
    let color: Color
    /// Core / capturer message for failures, shown under "Details".
    let raw: String?

    init(_ reason: StopReason) {
        switch reason {
        case .endOfDocument:
            self.init("Reached the end of the book", nil, "checkmark.circle.fill", .green)
        case .capReached:
            self.init("Stopped at the page limit", "The book may go on. Raise the limit in Options.",
                      "flag.checkered.circle.fill", .orange)
        case .cancelled:
            self.init("Capture stopped", nil, "stop.circle.fill", .secondary)
        case .captureFailed(let message):
            let (title, direction) = Self.failure(message)
            self.init(title, direction, "exclamationmark.triangle.fill", .red, raw: message)
        }
    }

    private init(_ title: String, _ direction: String?, _ symbol: String, _ color: Color, raw: String? = nil) {
        self.title = title
        self.direction = direction
        self.symbol = symbol
        self.color = color
        self.raw = raw
    }

    /// Maps the messages CaptureSession, KeySenderError and CapturerError produce.
    static func failure(_ m: String) -> (String, String) {
        func has(_ s: String) -> Bool { m.localizedCaseInsensitiveContains(s) }
        if has("page never turned") {
            return ("The page never turned", "Keep the book window in front and try again.")
        }
        if has("could not be brought to the front") {
            return ("The book window did not come to the front", "Close any dialog over it and try again.")
        }
        if has("Accessibility permission is off") {
            return ("Accessibility was turned off", "Allow it again, then start a new capture.")
        }
        if has("is gone") {
            return ("The browser quit", "Open the book again and start a new capture.")
        }
        if has("window was closed") {
            return ("The book window was closed", "Keep it open during the run.")
        }
        if has("minimized or moved to another Space") {
            return ("The book window was hidden", "Keep it visible on this Space during the run.")
        }
        if has("window was resized") {
            return ("The book window changed size", "Keep its size during the run.")
        }
        if has("save failed") {
            return ("Could not save a page", "Check the free disk space and try again.")
        }
        return ("The capture stopped with an error", "Try again. If it happens again, see Details.")
    }
}

/// Stage 3: check the pages, remove bad ones, save the PDF. Header: two bands — the outcome
/// (title, direction, meta + page actions) on the left, the run actions on the right.
struct ReviewView: View {
    @Bindable var model: AppModel
    @State private var viewer: PageRef?
    @State private var confirmTrash = false
    @State private var showDetails = false

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
                    .padding(.bottom, 14)
                Divider()
                if review.pages.isEmpty {
                    emptyState(review)
                } else {
                    grid(review)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: review.savedPDF)
            .animation(.easeInOut(duration: 0.2), value: review.cacheTrashed)
            .animation(.easeInOut(duration: 0.15), value: review.selection.isEmpty)
            .sheet(item: $viewer) { ref in
                PageViewer(model: model, start: ref.url)
            }
        }
    }

    // MARK: Header

    private func header(_ r: ReviewState) -> some View {
        let outcome = RunOutcome(r.reason)
        return HStack(alignment: .center, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: outcome.symbol)
                    .font(.system(size: 26))
                    .foregroundStyle(outcome.color)
                VStack(alignment: .leading, spacing: 4) {
                    Text(outcome.title)
                        .font(.title2.weight(.bold))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    if let direction = outcome.direction {
                        Text(direction)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    FlowRow(spacing: 10, lineSpacing: 6) {
                        metaItems(r, outcome)
                    }
                    if showDetails, let raw = outcome.raw {
                        Text(raw)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if hasActions(r) {
                actions(r)
                    .fixedSize()
            }
        }
        .animation(.easeInOut(duration: 0.15), value: showDetails)
    }

    /// Second band: what was captured (or where it was saved), then the page actions.
    @ViewBuilder
    private func metaItems(_ r: ReviewState, _ outcome: RunOutcome) -> some View {
        if let pdf = r.savedPDF {
            Text(savedLine(r, pdf))
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(pdf.path)
            Button("Show in Finder") { model.showSavedInFinder() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        } else {
            Text(meta(r))
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .contentTransition(.numericText())
        }
        if let raw = outcome.raw {
            Button {
                showDetails.toggle()
            } label: {
                HStack(spacing: 3) {
                    Text("Details")
                    Image(systemName: "chevron.down")
                        .imageScale(.small)
                        .rotationEffect(.degrees(showDetails ? 180 : 0))
                }
                .font(.callout)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.accent)
            .help(raw)
        }
        if !r.selection.isEmpty {
            Button {
                model.removeSelected()
            } label: {
                Label("Remove \(r.selection.count) \(r.selection.count == 1 ? "page" : "pages")", systemImage: "trash")
            }
            .controlSize(.small)
            .keyboardShortcut(.delete, modifiers: [])
            .disabled(r.locked)
            .help("Remove the selected pages from the PDF (⌫)")
        }
        // After a save the pill would push the header to a third band; the marks on the
        // thumbnails and ⋯ > Select incomplete pages stay.
        if r.savedPDF == nil { incompleteButton(r) }
    }

    /// "“Name” · 64 pages · 2 min 31 s · 2 removed". The name only when the user typed one.
    private func meta(_ r: ReviewState) -> String {
        var parts: [String] = []
        if let name = r.customName { parts.append("“\(name)”") }
        let duration = Settings.durationWords(r.duration)
        if r.captureNumbers.isEmpty {
            parts.append("Stopped after \(duration)")
        } else {
            parts.append("\(r.pages.count) \(r.pages.count == 1 ? "page" : "pages")")
            parts.append(duration)
            let removed = r.captureNumbers.count - r.pages.count
            if removed > 0 { parts.append("\(removed) removed") }
        }
        if r.cacheTrashed { parts.append("images in the Trash") }
        return parts.joined(separator: " · ")
    }

    /// "Saved to x.pdf · 38.7 MB · images in the Trash" (full path in the tooltip).
    private func savedLine(_ r: ReviewState, _ pdf: URL) -> String {
        var parts = ["Saved to " + pdf.lastPathComponent]
        if let bytes = r.savedBytes { parts.append(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) }
        if r.cacheTrashed { parts.append("images in the Trash") }
        return parts.joined(separator: " · ")
    }

    // MARK: Run actions

    private func hasActions(_ r: ReviewState) -> Bool {
        !r.pages.isEmpty || hasMoreMenu(r)
    }

    /// Nothing to delete for a run that never saved a page, or once the cache is gone.
    private func hasMoreMenu(_ r: ReviewState) -> Bool {
        !r.captureNumbers.isEmpty && !r.cacheTrashed
    }

    private func actions(_ r: ReviewState) -> some View {
        HStack(spacing: 8) {
            if hasMoreMenu(r) { moreMenu(r) }
            if !model.headless && !r.pages.isEmpty {
                Button {
                    model.newCapture()
                } label: {
                    Label("New capture", systemImage: "plus")
                }
                .disabled(r.saving)
            }
            if !r.pages.isEmpty {
                saveButton(r)
            }
        }
        .controlSize(.large)
    }

    /// Primary until a PDF exists; then "Save again…" steps back and Show in Finder leads.
    @ViewBuilder
    private func saveButton(_ r: ReviewState) -> some View {
        let button = Button {
            model.savePDF()
        } label: {
            if r.saving {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Saving…")
                }
            } else if r.savedPDF != nil {
                Label("Save again…", systemImage: "square.and.arrow.down")
            } else {
                Label("Save PDF…", systemImage: "square.and.arrow.down")
            }
        }
        .keyboardShortcut("s", modifiers: .command)
        .disabled(r.locked)
        if r.savedPDF == nil {
            button.buttonStyle(.borderedProminent)
        } else {
            button
        }
    }

    @ViewBuilder
    private func incompleteButton(_ r: ReviewState) -> some View {
        let incomplete = model.incompletePages
        if !incomplete.isEmpty && !r.locked {
            Button {
                model.selectIncomplete()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text("\(incomplete.count) \(incomplete.count == 1 ? "page looks" : "pages look") incomplete")
                    Image(systemName: "chevron.right")
                        .imageScale(.small)
                        .fontWeight(.semibold)
                }
                .font(.callout.weight(.medium))
                .foregroundStyle(.orange)
                .padding(.horizontal, 9)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.orange.opacity(0.14)))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("Much shorter than the other pages. Click to select them and show the first one.")
            .transition(.opacity)
        }
    }

    /// Rare actions: select all, select incomplete pages, delete the cached images.
    private func moreMenu(_ r: ReviewState) -> some View {
        Menu {
            Button("Select all pages") { model.selectAll() }
                .disabled(r.pages.isEmpty || r.locked)
            if !model.incompletePages.isEmpty {
                Button("Select incomplete pages") { model.selectIncomplete() }
                    .disabled(r.locked)
            }
            Divider()
            Button("Delete cached images…", role: .destructive) {
                // Without a saved PDF the images are the only copy of the run: ask first.
                if r.savedPDF == nil { confirmTrash = true } else { model.trashCache() }
            }
            .disabled(r.locked)
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 17))
                .foregroundStyle(Theme.accent)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More")
        .accessibilityLabel("More")
        .confirmationDialog(trashQuestion(r), isPresented: $confirmTrash) {
            Button("Delete", role: .destructive) { model.trashCache() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("No PDF was saved from this run.")
        }
    }

    private func trashQuestion(_ r: ReviewState) -> String {
        let n = r.captureNumbers.count
        return "Delete the \(n) captured \(n == 1 ? "page" : "pages")?"
    }

    // MARK: Grid

    private func grid(_ r: ReviewState) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 200), spacing: 16)], spacing: 18) {
                    ForEach(r.pages, id: \.self) { url in
                        PageCell(url: url,
                                 number: r.captureNumbers[url] ?? 0,
                                 selected: r.selection.contains(url),
                                 incomplete: r.incomplete.contains(url))
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
            .onChange(of: model.reviewScrollTarget) { _, target in
                scroll(proxy, to: target, animated: true)
            }
            .task {
                // A target set before the grid appeared (e.g. a snapshot state).
                try? await Task.sleep(for: .milliseconds(50))
                scroll(proxy, to: model.reviewScrollTarget, animated: false)
            }
        }
        .background(Theme.pageSurface)
    }

    private func scroll(_ proxy: ScrollViewProxy, to target: URL?, animated: Bool) {
        guard let target else { return }
        if animated {
            withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(target, anchor: .center) }
        } else {
            proxy.scrollTo(target, anchor: .center)
        }
        model.reviewScrollTarget = nil
    }

    private func emptyState(_ r: ReviewState) -> some View {
        let neverSaved = r.captureNumbers.isEmpty
        // The header already gives a direction for failures: no second instruction here.
        let headerDirects = RunOutcome(r.reason).direction != nil
        return ContentUnavailableView {
            Label(neverSaved ? "No pages captured" : "No pages left", systemImage: "doc.questionmark")
        } description: {
            if !neverSaved {
                Text("You removed every page.")
            } else if !headerDirects {
                Text("Open the book at the cover, then start a new capture.")
            }
        } actions: {
            if !model.headless {
                Button("New capture") { model.newCapture() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.pageSurface)
    }
}

/// Left-aligned row that wraps to more lines when the items do not fit. Items wider than the
/// row get the row width (so a long path truncates instead of overflowing).
struct FlowRow: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + lineSpacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: proposal.width.map { min($0, width) } ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for item in row.items {
                let size = item.size
                subviews[item.index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
                                           proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Item { let index: Int; let size: CGSize }
    private struct Row { var items: [Item] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for (i, view) in subviews.enumerated() {
            var size = view.sizeThatFits(.unspecified)
            if size.width > width { size = view.sizeThatFits(ProposedViewSize(width: width, height: nil)) }
            if size.width <= 0 && size.height <= 0 { continue }
            let needed = row.items.isEmpty ? size.width : row.width + spacing + size.width
            if needed > width && !row.items.isEmpty {
                rows.append(row)
                row = Row()
            }
            row.width = row.items.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.items.append(Item(index: i, size: size))
        }
        if !row.items.isEmpty { rows.append(row) }
        return rows
    }
}

/// One thumbnail with its capture number. Selected: an accent ring around the page with a
/// small gap. Incomplete: a thin orange border and ⚠ by the number.
private struct PageCell: View {
    let url: URL
    let number: Int
    let selected: Bool
    let incomplete: Bool
    @State private var hover = false

    var body: some View {
        VStack(spacing: 8) {
            ThumbnailImage(url: url, maxPixel: 400)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                .overlay {
                    if incomplete {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .strokeBorder(Color.orange, lineWidth: 1.5)
                    }
                }
                .shadow(color: .black.opacity(hover ? 0.22 : 0.12), radius: hover ? 6 : 3, y: 1)
                .overlay {
                    if selected {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Theme.accent, lineWidth: 3)
                            .padding(-6)   // 3 pt gap + 3 pt ring
                    }
                }
                .frame(height: 190)
                .frame(maxWidth: .infinity)
            HStack(spacing: 3) {
                if incomplete {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .imageScale(.small)
                }
                Text("\(number)")
            }
            .font(.caption.weight(.medium).monospacedDigit())
            .padding(.horizontal, 7)
            .padding(.vertical, 1)
            .foregroundStyle(selected ? Color.white : (incomplete ? Color.orange : Color.secondary))
            .background(Capsule().fill(selected ? Theme.accent : Color.clear))
        }
        .padding(8)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.12), value: selected)
        .help(incomplete ? "Capture \(number) — looks incomplete (much shorter than the other pages)" : "Capture \(number)")
    }
}

/// Large view of one page with ←/→ navigation. Esc closes.
struct PageViewer: View {
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
                // The capture number only when removals made it differ from the page number.
                if let capture = model.review?.captureNumbers[current], capture != index + 1 {
                    Text("Capture \(capture)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(12)
            Divider()
            ZStack {
                Theme.pageSurface
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
