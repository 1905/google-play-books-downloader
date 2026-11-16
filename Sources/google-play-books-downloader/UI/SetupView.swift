import SwiftUI

/// Stage 1, one centred column read top to bottom: permissions (loud only while one is
/// missing), the book window (the hero), quiet capture options, Start bar across the bottom.
/// The ScrollView scrolls when the content is taller than the window.
struct SetupView: View {
    @Bindable var model: AppModel
    private static let optionsID = "options"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    PermissionsCard(model: model)
                    SourceCard(model: model)
                    OptionsSection(model: model)
                        .id(Self.optionsID)
                }
                .frame(maxWidth: Theme.setupColumn)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, Theme.padding)
                .padding(.top, 12)
                .padding(.bottom, Theme.padding)
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
        .safeAreaInset(edge: .bottom, spacing: 0) { startBar }
    }

    private var startBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(alignment: .center, spacing: 14) {
                Group {
                    if let blocker = model.startBlocker {
                        Label(blocker, systemImage: "info.circle")
                            .foregroundStyle(.secondary)
                    } else {
                        HStack(spacing: 6) {
                            Label("Ready — hands off the mouse and keyboard.", systemImage: "checkmark.circle")
                                .foregroundStyle(.green)
                            KeyCap(text: "ESC")
                                .foregroundStyle(.secondary)
                            Text("stops")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .font(.callout)
                .lineLimit(1)
                .animation(.easeInOut(duration: 0.15), value: model.startBlocker)
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
            }
            .padding(.horizontal, Theme.padding)
            .padding(.vertical, 14)
        }
        .background(.bar)
    }
}
