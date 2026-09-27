/// Finds the page area of a window from what changes between two shots.
public enum PageZone {
    /// Block size `detect` uses by default. CaptureSession uses it too (zone growth margin).
    public static let defaultBlockSize = 4

    /// Rect in the coordinates of `before`/`after` (same size). nil if the page components'
    /// union bounding box covers < minAreaFraction of the image.
    ///
    /// A block is "changed" when its mean absolute difference is > `threshold`. Changed blocks
    /// are grouped into 8-connected components. Every component with at least `minComponentShare`
    /// of the largest component's block count counts as page. So two facing pages split by an
    /// unchanged gutter both stay, and small components (a toolbar page counter) drop out.
    /// Coverage is measured as the union bounding-box area, because real pages change unevenly
    /// (white areas stay white). The zone is that bounding box padded by one block and clamped
    /// to the image.
    public static func detect(before: GrayImage, after: GrayImage, blockSize: Int = defaultBlockSize,
                              threshold: Double = 8, minAreaFraction: Double = 0.10,
                              minComponentShare: Double = 0.25) -> PixelRect? {
        guard before.width == after.width, before.height == after.height,
              before.width > 0, before.height > 0, blockSize > 0 else { return nil }
        let w = before.width, h = before.height, bs = blockSize
        let bw = (w + bs - 1) / bs, bh = (h + bs - 1) / bs

        var changed = [Bool](repeating: false, count: bw * bh)
        for by in 0..<bh {
            for bx in 0..<bw {
                let x0 = bx * bs, y0 = by * bs
                let x1 = min(x0 + bs, w), y1 = min(y0 + bs, h)
                var sum = 0
                for y in y0..<y1 {
                    let row = y * w
                    for x in x0..<x1 {
                        sum += abs(Int(before.pixels[row + x]) - Int(after.pixels[row + x]))
                    }
                }
                changed[by * bw + bx] = Double(sum) / Double((x1 - x0) * (y1 - y0)) > threshold
            }
        }

        // Iterative flood fill over 8-connected changed blocks; collect every component's bbox.
        var seen = [Bool](repeating: false, count: bw * bh)
        var components: [(count: Int, minX: Int, minY: Int, maxX: Int, maxY: Int)] = []
        var stack = [Int]()
        for start in 0..<(bw * bh) where changed[start] && !seen[start] {
            seen[start] = true
            stack.append(start)
            var count = 0, minX = bw, minY = bh, maxX = -1, maxY = -1
            while let i = stack.popLast() {
                let bx = i % bw, by = i / bw
                count += 1
                minX = min(minX, bx); maxX = max(maxX, bx)
                minY = min(minY, by); maxY = max(maxY, by)
                for dy in -1...1 {
                    for dx in -1...1 {
                        let nx = bx + dx, ny = by + dy
                        guard nx >= 0, nx < bw, ny >= 0, ny < bh else { continue }
                        let j = ny * bw + nx
                        if changed[j] && !seen[j] {
                            seen[j] = true
                            stack.append(j)
                        }
                    }
                }
            }
            components.append((count, minX, minY, maxX, maxY))
        }
        guard let largest = components.map(\.count).max() else { return nil }
        let keep = components.filter { Double($0.count) >= minComponentShare * Double(largest) }
        let b = (minX: keep.map(\.minX).min()!, minY: keep.map(\.minY).min()!,
                 maxX: keep.map(\.maxX).max()!, maxY: keep.map(\.maxY).max()!)

        let bbox = PixelRect(x: b.minX * bs, y: b.minY * bs,
                             width: (b.maxX - b.minX + 1) * bs, height: (b.maxY - b.minY + 1) * bs)
            .clamped(width: w, height: h)
        guard Double(bbox.area) >= minAreaFraction * Double(w * h) else { return nil }
        return PixelRect(x: bbox.x - bs, y: bbox.y - bs, width: bbox.width + 2 * bs, height: bbox.height + 2 * bs)
            .clamped(width: w, height: h)
    }

    /// Shrinks `zone` while ≥ 95% of an edge row/col's pixels are within meanTol of one backdrop
    /// reference. References = uniform 4×4 patches sampled at 8 points along each edge
    /// of the zone. The zone is padded one block past the changed area, so its edges are
    /// normally backdrop or viewer chrome. Corners alone failed on Safari/macOS 26: a grey
    /// toolbar strip filled both top corners and a noisy control bar both bottom corners, so the
    /// black side backdrop never became a reference. Only a line that matches a reference is
    /// trimmed, so page content and a page's own margins (not a reference colour) stay. Max trim
    /// maxFraction per side, at least 20% of the zone kept. 0.75 because in a 2-up viewer the
    /// cover sits in one half of a spread-wide zone, so one side needs > 50% trimmed.
    ///
    /// Top and bottom are trimmed first over the full zone width, then left and right over
    /// the remaining rows.
    public static func trim(_ image: GrayImage, zone: PixelRect, maxFraction: Double = 0.75,
                            stdMax: Double = 6, meanTol: Double = 10) -> PixelRect {
        let z = zone.clamped(width: image.width, height: image.height)
        guard z.area > 0 else { return z }
        let backdrop = Backdrop(image, levels: Backdrop.samples(image, zone: z, stdMax: stdMax).map(\.level),
                                meanTol: meanTol)
        func isBackdrop(_ r: PixelRect) -> Bool { backdrop.matches(r) }
        let maxY = Int(Double(z.height) * maxFraction), maxX = Int(Double(z.width) * maxFraction)
        let keepY = max(1, z.height / 5), keepX = max(1, z.width / 5)

        var top = 0, bottom = 0
        while top < maxY, isBackdrop(PixelRect(x: z.x, y: z.y + top, width: z.width, height: 1)) { top += 1 }
        while bottom < maxY, z.height - top - bottom > keepY,
              isBackdrop(PixelRect(x: z.x, y: z.maxY - 1 - bottom, width: z.width, height: 1)) { bottom += 1 }
        let y = z.y + top, h = z.height - top - bottom

        var left = 0, right = 0
        while left < maxX, isBackdrop(PixelRect(x: z.x + left, y: y, width: 1, height: h)) { left += 1 }
        while right < maxX, z.width - left - right > keepX,
              isBackdrop(PixelRect(x: z.maxX - 1 - right, y: y, width: 1, height: h)) { right += 1 }
        return PixelRect(x: z.x + left, y: y, width: z.width - left - right, height: h)
    }

    /// Page rect inside `zone` by projection profiles, for viewers that show more than the page
    /// (Google Play Books scrolls vertically: below the spread comes a backdrop gap and the top
    /// of the next spread, which also changes on every turn and so sits in the zone).
    ///
    /// 1. Backdrop references: uniform 4×4 patches at 8 points along each zone edge, as in
    ///    `trim`. "Strong" backdrop: a level seen on ≥ 2 edges (corners not counted), or on an
    ///    edge that lies inside the image (`detect` padded it past the change, so it is
    ///    backdrop). Other levels are "weak": chrome (a toolbar strip), or page content cut by a
    ///    zone edge on the image border (the peeking next spread fills the bottom edge with
    ///    paper white). Levels ≥ `paperLevel` are never strong: a zone edge inside the image
    ///    can still run through a page's white margin. No strong level: falls back to `trim`.
    /// 2. Rows: a row is backdrop when ≥ 95% of it matches one strong level. Of the maximal runs
    ///    of non-backdrop rows ≥ 3% of the zone height, keep the tallest (ties: nearest the
    ///    zone's vertical center). Drops the peeking next spread and top/bottom chrome that has a
    ///    backdrop gap.
    /// 3. Columns over the kept rows, same rule. Runs ≥ 3% of the zone width are grouped while
    ///    the gap to the next run is < 4% of the width (a spread's pages have only a thin gutter
    ///    between them); the widest group wins. A cover alone in half a spread-wide zone loses the
    ///    backdrop half.
    /// 4. Chrome glued to the page (no gap): where the rect still touches a zone edge, lines are
    ///    peeled off while they match a weak non-paper level seen on that same edge (≤ 75% per side);
    ///    then step 3 runs again over the new rows. Weak levels never split the page in step 2,
    ///    so white paper at the zone's bottom edge cannot cut a blank page's margins.
    /// No backdrop reference or no qualifying run: falls back to `trim`.
    /// Gray level from which an edge patch is taken as page paper, never strong backdrop.
    /// Google Play Books shows paper-white pages on a dark backdrop (≈ 22–30). A zone edge can
    /// run through a page's unchanged white margin (the first turn only changes the art), and
    /// paper white as "backdrop" breaks a light page into backdrop columns.
    static let paperLevel = 200

    public static func segment(_ image: GrayImage, zone: PixelRect) -> PixelRect {
        let z = zone.clamped(width: image.width, height: image.height)
        guard z.area > 0 else { return z }
        let samples = Backdrop.samples(image, zone: z, stdMax: 6)
        guard !samples.isEmpty else { return trim(image, zone: z) }
        var edgesOf: [Int: Set<Edge>] = [:]
        for s in samples where !s.corner { edgesOf[s.level, default: []].insert(s.edge) }
        // An edge inside the image was padded past the changed area by `detect`, so it shows
        // backdrop. An edge on the image border may cut through content.
        let inner: Set<Edge> = Set([z.y > 0 ? Edge.top : nil, z.maxY < image.height ? .bottom : nil,
                                    z.x > 0 ? .left : nil, z.maxX < image.width ? .right : nil].compactMap { $0 })
        let strongLevels = Set(samples.filter {
            $0.level < paperLevel && (edgesOf[$0.level, default: []].count >= 2 || inner.contains($0.edge))
        }.map(\.level))
        guard !strongLevels.isEmpty else { return trim(image, zone: z) }
        let strong = Backdrop(image, levels: Array(strongLevels), meanTol: 10)
        func weak(_ e: Edge) -> Backdrop {
            // Paper is never peeled: a page's own white margin touches the zone edge.
            Backdrop(image, levels: Array(Set(samples.filter {
                $0.edge == e && !strongLevels.contains($0.level) && $0.level < paperLevel
            }.map(\.level))),
                     meanTol: 10)
        }

        let rowRuns = runs(count: z.height, minLength: max(1, Int((0.03 * Double(z.height)).rounded(.up)))) {
            !strong.matches(PixelRect(x: z.x, y: z.y + $0, width: z.width, height: 1))
        }
        let mid = Double(z.height) / 2
        guard var rows = rowRuns.max(by: { a, b in
            a.count != b.count ? a.count < b.count
                : abs(Double(a.lowerBound + a.upperBound) / 2 - mid) > abs(Double(b.lowerBound + b.upperBound) / 2 - mid)
        }) else { return trim(image, zone: z) }

        func columns(_ rows: Range<Int>) -> Range<Int>? {
            let colRuns = runs(count: z.width, minLength: max(1, Int((0.03 * Double(z.width)).rounded(.up)))) {
                !strong.matches(PixelRect(x: z.x + $0, y: z.y + rows.lowerBound, width: 1, height: rows.count))
            }
            let maxGap = 0.04 * Double(z.width)
            var groups: [Range<Int>] = []
            for r in colRuns {
                if let last = groups.last, Double(r.lowerBound - last.upperBound) < maxGap {
                    groups[groups.count - 1] = last.lowerBound..<r.upperBound
                } else {
                    groups.append(r)
                }
            }
            return groups.max(by: { $0.count < $1.count })
        }
        guard var cols = columns(rows) else { return trim(image, zone: z) }

        // Step 4: peel chrome glued to the page on the zone edges it touches.
        func row(_ y: Int) -> PixelRect { PixelRect(x: z.x + cols.lowerBound, y: z.y + y, width: cols.count, height: 1) }
        func col(_ x: Int) -> PixelRect { PixelRect(x: z.x + x, y: z.y + rows.lowerBound, width: 1, height: rows.count) }
        let maxRows = Int(Double(rows.count) * 0.75), maxCols = Int(Double(cols.count) * 0.75)
        var lo = rows.lowerBound, hi = rows.upperBound
        if lo == 0 { let w = weak(.top); while lo - rows.lowerBound < maxRows, w.matches(row(lo)) { lo += 1 } }
        if hi == z.height { let w = weak(.bottom); while rows.upperBound - hi < maxRows, hi > lo + 1, w.matches(row(hi - 1)) { hi -= 1 } }
        if lo != rows.lowerBound || hi != rows.upperBound {
            rows = lo..<hi
            guard let c = columns(rows) else { return trim(image, zone: z) }
            cols = c
        }
        var left = cols.lowerBound, right = cols.upperBound
        if left == 0 { let w = weak(.left); while left - cols.lowerBound < maxCols, w.matches(col(left)) { left += 1 } }
        if right == z.width { let w = weak(.right); while cols.upperBound - right < maxCols, right > left + 1, w.matches(col(right - 1)) { right -= 1 } }
        cols = left..<right
        return PixelRect(x: z.x + cols.lowerBound, y: z.y + rows.lowerBound, width: cols.count, height: rows.count)
    }

    /// Maximal runs of indices in 0..<count where `isOn` holds, at least `minLength` long.
    private static func runs(count: Int, minLength: Int, _ isOn: (Int) -> Bool) -> [Range<Int>] {
        var out: [Range<Int>] = []
        var start: Int?
        for i in 0...count {
            if i < count, isOn(i) {
                if start == nil { start = i }
            } else if let s = start {
                if i - s >= minLength { out.append(s..<i) }
                start = nil
            }
        }
        return out
    }

    enum Edge { case top, bottom, left, right }

    /// Backdrop colour model: lines matching one of a few gray levels.
    struct Backdrop {
        let image: GrayImage
        /// Gray value → bitmask of the reference levels it is within meanTol of. ≤ 32 levels.
        private var match = [UInt32](repeating: 0, count: 256)
        private let levelCount: Int

        /// Uniform (std < stdMax) 4×4 patches at 8 points along each zone edge: rounded mean,
        /// edge, and whether the patch is a zone corner (i = 0 or 7). See `trim` for why edges.
        static func samples(_ image: GrayImage, zone z: PixelRect, stdMax: Double)
            -> [(level: Int, edge: Edge, corner: Bool)] {
            var out: [(level: Int, edge: Edge, corner: Bool)] = []
            for i in 0..<8 {
                let px = z.x + (z.width - 4) * i / 7, py = z.y + (z.height - 4) * i / 7
                for (x, y, e) in [(px, z.y, Edge.top), (px, z.maxY - 4, .bottom), (z.x, py, .left), (z.maxX - 4, py, .right)] {
                    let (mean, std) = image.meanAndStd(PixelRect(x: max(x, z.x), y: max(y, z.y), width: 4, height: 4)
                        .clamped(width: z.maxX, height: z.maxY))
                    if std < stdMax { out.append((Int(mean.rounded()), e, i == 0 || i == 7)) }
                }
            }
            return out
        }

        init(_ image: GrayImage, levels: [Int], meanTol: Double) {
            self.image = image
            // Distinct levels, so the per-pixel check stays cheap. ≤ 32 samples, so ≤ 32 levels.
            let distinct = Array(Set(levels))
            levelCount = distinct.count
            for v in 0..<256 {
                for (i, l) in distinct.enumerated() where Double(abs(v - l)) < meanTol { match[v] |= 1 << UInt32(i) }
            }
        }

        /// Backdrop line: ≥ 95% of its pixels within meanTol of one reference. Not a plain std
        /// test, because a side column also crosses a thin toolbar or control bar that is not
        /// backdrop. One reference must cover the line: a page line mixes colours that may each
        /// be a "reference" (flat blocks at the zone edge), but never 95% of one of them.
        func matches(_ r: PixelRect) -> Bool {
            guard levelCount > 0, r.area > 0 else { return false }
            let need = 0.95 * Double(r.area)
            var hits = [Int](repeating: 0, count: levelCount)
            var best = 0, remaining = r.area
            for yy in r.y..<r.maxY {
                let row = yy * image.width
                for xx in r.x..<r.maxX {
                    var m = match[Int(image.pixels[row + xx])]
                    while m != 0 {
                        let i = m.trailingZeroBitCount
                        hits[i] += 1
                        best = max(best, hits[i])
                        m &= m - 1
                    }
                    remaining -= 1
                    // No level can still reach 95%.
                    if Double(best + remaining) < need { return false }
                }
            }
            return Double(best) >= need
        }
    }

    /// True if `component` sticks out of `zone` by more than `margin` px on any side.
    public static func exceeds(_ component: PixelRect, zone: PixelRect, margin: Int) -> Bool {
        component.x < zone.x - margin || component.y < zone.y - margin
            || component.maxX > zone.maxX + margin || component.maxY > zone.maxY + margin
    }
}
