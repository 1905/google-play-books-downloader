import SwiftUI

/// Stage 1, one centred column read top to bottom: permissions (loud only while one is
/// missing), the book window (the main element), quiet capture options, Start bar across the
/// bottom. The column is centred vertically while it fits and scrolls when it does not.
struct SetupView: View {
    @Bindable var model: AppModel
    private static let optionsID = "options"

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geo in
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            PermissionsCard(model: model)
                            SourceCard(model: model)
                            OptionsSection(model: model)
                                .id(Self.optionsID)
                        }
                        .frame(maxWidth: Theme.setupColumn)
                        .padding(.horizontal, Theme.padding)
                        .padding(.vertical, Theme.padding)
                        // At least the visible height: centred while it fits, top-aligned when it scrolls.
                        .frame(maxWidth: .infinity, minHeight: geo.size.height)
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    // Opened options are fully visible: scroll them into view.
                    .onChange(of: model.optionsExpanded) { _, open in
                        guard open else { return }
                        Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(220))   // after the open animation
                            withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(Self.optionsID, anchor: .bottom) }
                        }
                    }
                    .onAppear {
                        if model.optionsExpanded { proxy.scrollTo(Self.optionsID, anchor: .bottom) }
                    }
                }
            }
            startBar
        }
    }

    /// Every blocker is already explained in the body (permissions card, window card, its
    /// banner), so the bar only speaks when Start is enabled; the reason stays in the tooltip.
    private var startBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(alignment: .center, spacing: 14) {
                if model.startBlocker == nil {
                    HStack(spacing: 6) {
                        Label("Ready — hands off the mouse and keyboard.", systemImage: "checkmark.circle")
                            .foregroundStyle(.green)
                        KeyCap(text: "ESC")
                            .foregroundStyle(.secondary)
                        Text("stops")
                            .foregroundStyle(.secondary)
                    }
                    .font(.callout)
                    .lineLimit(1)
                    .transition(.opacity)
                }
                Spacer(minLength: 8)
                Button {
                    model.start()
                } label: {
                    Label("Start capture", systemImage: "record.circle")
                        .font(.body.weight(.semibold))
                        .padding(.horizontal, 6)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .disabled(model.startBlocker != nil)
                .help(model.startBlocker ?? "Start turning pages and saving them")
            }
            .animation(.easeInOut(duration: 0.15), value: model.startBlocker)
            .padding(.horizontal, Theme.padding)
            .padding(.vertical, 14)
        }
        .background(.bar)
    }
}
