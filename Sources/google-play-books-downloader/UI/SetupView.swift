import SwiftUI

/// Stage 1, two columns: permissions + viewer window on the left, settings on the right,
/// Start bar across the bottom. The ScrollView only scrolls when the window is made smaller
/// than the content (e.g. while the permissions card is expanded).
struct SetupView: View {
    @Bindable var model: AppModel

    var body: some View {
        ScrollView {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 16) {
                    PermissionsCard(model: model)
                    SourceCard(model: model)
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                SettingsCard(model: model)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .padding(.horizontal, Theme.padding)
            .padding(.top, 12)
            .padding(.bottom, Theme.padding)
        }
        .scrollBounceBehavior(.basedOnSize)
        .safeAreaInset(edge: .bottom, spacing: 0) { startBar }
    }

    private var startBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(alignment: .center, spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    if let blocker = model.startBlocker {
                        Label(blocker, systemImage: "info.circle")
                            .foregroundStyle(.secondary)
                    } else {
                        Label("Ready. Leave the mouse and keyboard alone during the run.", systemImage: "checkmark.circle")
                            .foregroundStyle(.green)
                    }
                    HStack(spacing: 4) {
                        Text("Press")
                        KeyCap(text: "ESC")
                        Text("at any time to stop.")
                    }
                    .foregroundStyle(.tertiary)
                }
                .font(.callout)
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
