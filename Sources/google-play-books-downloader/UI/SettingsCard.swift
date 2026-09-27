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

/// Key, page-animation wait, page cap, run name. Spreads are always split (Play Books two-page view). Every change is saved at once.
struct SettingsCard: View {
    @Bindable var model: AppModel
    /// Slider range. `Settings` still accepts up to 10 s (CLI / older settings).
    private static let sliderRange: ClosedRange<Double> = 0...3

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 0) {
                CardHeader(title: "Capture settings", symbol: "slider.horizontal.3")
                    .padding(.bottom, 12)
                row("Turn page with", symbol: "keyboard") { keyControls }
                Divider().padding(.vertical, 10)
                row("Page animation", symbol: "timer") { latencyControls }
                Divider().padding(.vertical, 10)
                row("Safety limit", symbol: "stop.circle") { maxPagesControls }
                Divider().padding(.vertical, 10)
                row("Name", symbol: "character.cursor.ibeam") { nameControls }
            }
        }
    }

    private func row<C: View>(_ title: String, symbol: String, @ViewBuilder _ content: () -> C) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Label(title, systemImage: symbol)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .frame(width: 132, alignment: .leading)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Key

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
                Button("Test") { model.testKey() }
                    .disabled(model.source == nil || model.sourceHealth != .ok || !model.permissions.accessibility)
                    .help("Send the key once to the Play Books window")
            }
            Text(model.testKeyMessage ?? "Google Play Books turns pages with Page Down")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Latency

    private var latencyControls: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Slider(value: Binding(
                    get: { min(max(model.settings.extraLatency, Self.sliderRange.lowerBound), Self.sliderRange.upperBound) },
                    set: { model.settings.extraLatency = ($0 * 10).rounded() / 10 }
                ), in: Self.sliderRange, step: 0.1)
                .frame(minWidth: 120)
                Text(String(format: "%.1f s", model.settings.extraLatency))
                    .font(.callout.monospacedDigit())
                    .frame(width: 44, alignment: .trailing)
            }
            Text("Extra wait after the page changes. Raise it for slow or animated page turns.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Max pages

    private var maxPagesControls: some View {
        VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 6) {
            TextField("Pages", value: Binding(
                get: { model.settings.maxPages },
                set: { model.settings.maxPages = min(max($0, Settings.maxPagesRange.lowerBound), Settings.maxPagesRange.upperBound) }
            ), format: .number.grouping(.never))
            .multilineTextAlignment(.trailing)
            .frame(width: 64)
            Stepper("Stop after", value: $model.settings.maxPages, in: Settings.maxPagesRange, step: 10)
                .labelsHidden()
            Text("pages max")
                .foregroundStyle(.secondary)
        }
            Text("The run stops by itself at the end of the book. This is only a hard stop in case end detection misses.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Name

    /// Format example for the empty name, fixed at launch.
    private static let nameExample = CachePaths.defaultRunName(date: Date())

    private var nameControls: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Not inside a TimelineView: re-rendering the field every second can drop an edit in progress.
            TextField("Date and time", text: $model.runNameText)
                .textFieldStyle(.roundedBorder)
            Text("Cache folder and default PDF name. Empty = date and time (\(Self.nameExample)).")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
