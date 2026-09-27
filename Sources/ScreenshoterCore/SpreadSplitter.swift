/// Cuts a two-page spread into left and right pages.
public enum SpreadSplitter {
    /// Landscape check: width > height × ratio.
    public static func isSpread(_ r: PixelRect, ratio: Double = 1.15) -> Bool {
        Double(r.width) > Double(r.height) * ratio
    }

    /// [left, right], cut at the horizontal center; left gets floor(width / 2).
    public static func split(_ r: PixelRect) -> [PixelRect] {
        cut(r, at: r.x + r.width / 2)
    }

    /// [left, right], cut at the gutter found in `image` within ±6% of r's width around its
    /// center; falls back to `split(_:)` (center) when no column clearly stands out.
    /// `r` is in `image` coordinates. The right page starts at the gutter column.
    ///
    /// Column score = mean over r's rows of |L(x+1) − L(x−1)| (vertical edge) plus, for a thin
    /// line whose column mean differs from the means 2 px left and right by > 12, twice the
    /// smaller difference. Candidates are only columns that show a feature (edge or line,
    /// > 6 levels) in ≥ 90% of the rows: text and noise line up in some rows only, a gutter runs
    /// the full page height. The best candidate wins if its score is ≥ 8 and ≥ 2× the median
    /// score of all window columns.
    public static func split(_ r: PixelRect, in image: GrayImage) -> [PixelRect] {
        let c = r.clamped(width: image.width, height: image.height)
        let center = r.x + r.width / 2
        let reach = Int(Double(r.width) * 0.06)
        // Every probed pixel (x−2...x+2) must stay inside the rect.
        let lo = max(center - reach, c.x + 2), hi = min(center + reach, c.maxX - 3)
        guard c == r, c.height > 0, lo <= hi else { return split(r) }

        let w = image.width, px = image.pixels
        // Column means over the window plus 2 px each side (for the thin-line test).
        let base = lo - 2
        let means = (base...(hi + 2)).map { x -> Double in
            var sum = 0
            for y in c.y..<c.maxY { sum += Int(px[y * w + x]) }
            return Double(sum) / Double(c.height)
        }

        var scores: [(x: Int, score: Double, coverage: Double)] = []
        for x in lo...hi {
            var edgeSum = 0, featureRows = 0
            for y in c.y..<c.maxY {
                let row = y * w
                let l = Int(px[row + x - 1]), m = Int(px[row + x]), rr = Int(px[row + x + 1])
                let edge = abs(rr - l)
                let line = min(abs(m - Int(px[row + x - 2])), abs(m - Int(px[row + x + 2])))
                edgeSum += edge
                if max(edge, line) > 6 { featureRows += 1 }
            }
            let i = x - base, m = means[i]
            let depth = min(abs(m - means[i - 2]), abs(m - means[i + 2]))
            let bonus = depth > 12 ? 2 * depth : 0
            scores.append((x, Double(edgeSum) / Double(c.height) + bonus,
                           Double(featureRows) / Double(c.height)))
        }

        let sorted = scores.map(\.score).sorted()
        let median = sorted[sorted.count / 2]
        // Ties go right: a plain edge scores equally on both sides of the boundary, and the
        // right one is the first column of the right page.
        guard let best = scores.filter({ $0.coverage >= 0.9 })
                .max(by: { $0.score < $1.score || ($0.score == $1.score && $0.x < $1.x) }),
              best.score >= 8, best.score >= 2 * median else { return split(r) }
        return cut(r, at: best.x)
    }

    private static func cut(_ r: PixelRect, at x: Int) -> [PixelRect] {
        let lw = x - r.x
        return [
            PixelRect(x: r.x, y: r.y, width: lw, height: r.height),
            PixelRect(x: x, y: r.y, width: r.width - lw, height: r.height),
        ]
    }
}
