import AppKit
import ScreenshoterCore

/// Save-panel accessory: "PDF size:" popup with an estimated file size per preset.
/// The last choice is kept in UserDefaults under `pdfSize`; the default is `.balanced`.
@MainActor
final class PDFSizeAccessory {
    static let defaultsKey = "pdfSize"

    let view: NSView
    private let popup = NSPopUpButton(frame: .zero, pullsDown: false)

    /// `pageBytes`: sum of the page file sizes, the base of the estimates.
    init(pageBytes: Int64, defaults: UserDefaults = .standard) {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        for size in PDFSize.allCases {
            let estimate = formatter.string(fromByteCount: Int64(Double(pageBytes) * size.estimateFactor))
            popup.addItem(withTitle: "\(Self.title(size)) — ≈ \(estimate)")
        }
        let stored = defaults.string(forKey: Self.defaultsKey).flatMap(PDFSize.init(rawValue:)) ?? .balanced
        popup.selectItem(at: PDFSize.allCases.firstIndex(of: stored) ?? 0)

        let label = NSTextField(labelWithString: "PDF size:")
        let row = NSStackView(views: [label, popup])
        row.orientation = .horizontal
        row.spacing = 8
        row.edgeInsets = NSEdgeInsets(top: 10, left: 20, bottom: 10, right: 20)
        row.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView()
        container.addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: container.topAnchor),
            row.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            row.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            row.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor),
        ])
        container.frame = NSRect(origin: .zero, size: row.fittingSize)
        view = container
    }

    var selected: PDFSize { PDFSize.allCases[max(popup.indexOfSelectedItem, 0)] }

    func remember(defaults: UserDefaults = .standard) {
        defaults.set(selected.rawValue, forKey: Self.defaultsKey)
    }

    static func title(_ size: PDFSize) -> String {
        switch size {
        case .full: return "Full (largest)"
        case .balanced: return "Balanced"
        case .small: return "Small"
        }
    }
}
