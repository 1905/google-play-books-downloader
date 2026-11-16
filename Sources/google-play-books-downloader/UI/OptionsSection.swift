import ScreenshoterCore
import SwiftUI

extension NextKey {
    var displayName: String {
        switch self {
        case .space: return "Space"
        case .right: return "Right arrow"
        case .down: return "Down arrow"
        case .pageDown: return "Page Down"
        case .returnKey: return "Return"
        }
    }

    var glyph: String {
        switch self {
        case .space: return "␣"
        case .right: return "→"
        case .down: return "↓"
        case .pageDown: return "⇟"
        case .returnKey: return "⏎"
        }
    }
}

/// Capture options under the window card: a one-line summary with an "Options" handle;
/// the controls open below it. Spreads are always split (Play Books two-page view).
/// Every change is saved at once.
struct OptionsSection: View {
    @Bindable var model: AppModel
    /// Slider range. `Settings` still accepts up to 10 s (CLI / older settings).
    private static let sliderRange: ClosedRange<Double> = 0...3
    /// Format example for the empty name, fixed at launch.
    private static let nameExample = CachePaths.defaultRunName(date: Date())

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            summaryRow
            if model.optionsExpanded {
                controls
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.optionsExpanded)
    }

    // MARK: Summary

    private var summary: String {
        let s = model.settings
        var parts = [s.nextKey.displayName,
                     String(format: "%.1f s wait", s.extraLatency),
                     "max \(s.maxPages) pages"]
        let name = model.runNameText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { parts.append("“\(name)”") }
        return parts.joined(separator: " · ")
    }

    private var summaryRow: some View {
        Button {
            model.optionsExpanded.toggle()
        } label: {
            HStack(spacing: 8) {
                // While open, the controls show the same values: only the handle stays.
                if !model.optionsExpanded {
                    Image(systemName: "slider.horizontal.3")
                    Text(summary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 8)
                Text("Options")
                    .foregroundStyle(Theme.accent)
                Image(systemName: "chevron.down")
                    .imageScale(.small)
                    .foregroundStyle(Theme.accent)
                    .rotationEffect(.degrees(model.optionsExpanded ? 180 : 0))
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(model.optionsExpanded ? "Hide the capture options" : "Change the page-turn key, wait, page limit and name")
        .accessibilityLabel("Capture options: \(summary)")
    }

    // MARK: Controls

    private var controls: some View {
        Card {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 14) {
                GridRow {
                    label("Turn page with")
                    keyControls
                }
                GridRow {
                    label("Wait after a turn")
                    latencyControls
                }
                GridRow {
                    label("Stop after")
                    maxPagesControls
                }
                GridRow {
                    label("Name")
                    nameControls
                }
            }
        }
    }

    private func label(_ title: String) -> some View {
        Text(title)
            .foregroundStyle(.secondary)
            .gridColumnAlignment(.trailing)
            .lineLimit(1)
    }

    private var keyControls: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Picker("Turn page with", selection: $model.settings.nextKey) {
                    ForEach(NextKey.allCases, id: \.self) { k in
                        Text("\(k.glyph)  \(k.displayName)").tag(k)
                    }
                }
                .labelsHidden()
                .fixedSize()
                .help("The key that turns the page. Google Play Books uses Page Down.")
                Button("Test") { model.testKey() }
                    .disabled(model.source == nil || model.sourceHealth != .ok || !model.permissions.accessibility)
                    .help("Send the key once to the Play Books window")
            }
            if let message = model.testKeyMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var latencyControls: some View {
        HStack(spacing: 10) {
            Slider(value: Binding(
                get: { min(max(model.settings.extraLatency, Self.sliderRange.lowerBound), Self.sliderRange.upperBound) },
                set: { model.settings.extraLatency = ($0 * 10).rounded() / 10 }
            ), in: Self.sliderRange, step: 0.1)
            .frame(width: 200)
            Text(String(format: "%.1f s", model.settings.extraLatency))
                .font(.callout.monospacedDigit())
                .frame(width: 44, alignment: .leading)
        }
        .help("Extra wait after the page changes. Raise it for slow or animated page turns.")
    }

    private var maxPagesControls: some View {
        HStack(spacing: 6) {
            TextField("Pages", value: Binding(
                get: { model.settings.maxPages },
                set: { model.settings.maxPages = min(max($0, Settings.maxPagesRange.lowerBound), Settings.maxPagesRange.upperBound) }
            ), format: .number.grouping(.never))
            .multilineTextAlignment(.trailing)
            .frame(width: 64)
            Stepper("Stop after", value: $model.settings.maxPages, in: Settings.maxPagesRange, step: 10)
                .labelsHidden()
            Text("pages")
                .foregroundStyle(.secondary)
        }
        .help("A hard stop. The run normally stops by itself at the end of the book.")
    }

    private var nameControls: some View {
        // Not inside a TimelineView: re-rendering the field every second can drop an edit in progress.
        TextField("Date and time", text: $model.runNameText)
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: 280)
            .help("Cache folder and default PDF name. Empty: date and time (\(Self.nameExample)).")
    }
}
