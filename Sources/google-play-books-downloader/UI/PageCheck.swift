import Foundation
import ImageIO

/// Finds pages that are probably cut off: much shorter than the typical page of the run.
enum PageCheck {
    /// A page is "incomplete" when its height is below this share of the median height.
    static let minShareOfMedian = 0.6

    /// Indices of heights below 60 % of the median (upper median for even counts).
    /// Needs at least 2 pages; zero and negative heights count as incomplete.
    static func incompleteIndices(heights: [Int]) -> [Int] {
        guard heights.count >= 2 else { return [] }
        let median = Double(heights.sorted()[heights.count / 2])
        guard median > 0 else { return [] }
        return heights.indices.filter { Double(heights[$0]) < median * minShareOfMedian }
    }

    /// Pixel height from the file header, without decoding the image. nil if unreadable.
    static func pixelHeight(of url: URL) -> Int? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        else { return nil }
        return (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue
    }

    /// Incomplete pages among `urls`. Unreadable files are skipped, not flagged.
    static func incompletePages(_ urls: [URL]) -> Set<URL> {
        let known = urls.compactMap { u in pixelHeight(of: u).map { (u, $0) } }
        return Set(incompleteIndices(heights: known.map(\.1)).map { known[$0].0 })
    }
}
