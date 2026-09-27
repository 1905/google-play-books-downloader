import CoreGraphics

/// Integer pixel rectangle, top-left origin (same convention as `CGImage.cropping(to:)`).
public struct PixelRect: Equatable {
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var maxX: Int { x + width }
    public var maxY: Int { y + height }
    public var area: Int { width * height }

    /// Multiplies all fields by `f`.
    public func scaled(by f: Int) -> PixelRect {
        PixelRect(x: x * f, y: y * f, width: width * f, height: height * f)
    }

    /// Intersection with `0..<width × 0..<height`. Empty result has zero width/height.
    public func clamped(width w: Int, height h: Int) -> PixelRect {
        let x0 = min(max(x, 0), w), y0 = min(max(y, 0), h)
        let x1 = min(max(maxX, x0), w), y1 = min(max(maxY, y0), h)
        return PixelRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    public var cgRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }
}

/// 8-bit grayscale image, row-major, top row first.
public struct GrayImage: Equatable {
    public let width: Int
    public let height: Int
    public var pixels: [UInt8]

    public init(width: Int, height: Int, pixels: [UInt8]) {
        precondition(width >= 0 && height >= 0 && pixels.count == width * height)
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    public init(width: Int, height: Int, fill: UInt8) {
        self.init(width: width, height: height, pixels: [UInt8](repeating: fill, count: width * height))
    }

    /// Draws `cgImage` into a DeviceGray context of size `width/downscale × height/downscale`.
    public init?(cgImage: CGImage, downscale: Int = 1) {
        let d = max(downscale, 1)
        let w = max(cgImage.width / d, 1), h = max(cgImage.height / d, 1)
        var buf = [UInt8](repeating: 0, count: w * h)
        let ok = buf.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }
        self.init(width: w, height: h, pixels: buf)
    }

    /// The whole image as a rect at the origin.
    public var bounds: PixelRect { PixelRect(x: 0, y: 0, width: width, height: height) }

    public subscript(x: Int, y: Int) -> UInt8 {
        get { pixels[y * width + x] }
        set { pixels[y * width + x] = newValue }
    }

    /// Crop to `r` clamped to the image bounds.
    public func cropped(_ r: PixelRect) -> GrayImage {
        let c = r.clamped(width: width, height: height)
        var out = [UInt8]()
        out.reserveCapacity(c.area)
        for y in c.y..<c.maxY {
            let start = y * width + c.x
            out.append(contentsOf: pixels[start..<start + c.width])
        }
        return GrayImage(width: c.width, height: c.height, pixels: out)
    }

    /// Box-filter resize: each output pixel is the rounded mean of the source cells it covers.
    public func resized(width nw: Int, height nh: Int) -> GrayImage {
        guard width > 0, height > 0, nw > 0, nh > 0 else {
            return GrayImage(width: max(nw, 0), height: max(nh, 0), fill: 0)
        }
        let xs = (0...nw).map { $0 * width / nw }
        let ys = (0...nh).map { $0 * height / nh }
        var out = [UInt8](repeating: 0, count: nw * nh)
        for oy in 0..<nh {
            let y0 = ys[oy], y1 = max(ys[oy + 1], y0 + 1)
            for ox in 0..<nw {
                let x0 = xs[ox], x1 = max(xs[ox + 1], x0 + 1)
                var sum = 0
                for y in y0..<y1 {
                    let row = y * width
                    for x in x0..<x1 { sum += Int(pixels[row + x]) }
                }
                let n = (y1 - y0) * (x1 - x0)
                out[oy * nw + ox] = UInt8((sum + n / 2) / n)
            }
        }
        return GrayImage(width: nw, height: nh, pixels: out)
    }

    /// Near-blank test for a page crop `r` (clamped). Ignores a `margin` share on every side
    /// (page edge shading, gutter). "Ink" = inner pixels that differ from the inner median by
    /// > `inkDelta`. Near-blank when ink is < `inkFraction` of the inner area, or all ink fits
    /// in a bounding box < `inkBoxFraction` of the inner area (a centered loading spinner, a page
    /// number, a small logo). Text and art spread ink over the page and fail both.
    /// Empty rect → true.
    public func isNearBlank(_ r: PixelRect, margin: Double = 0.05, inkDelta: Int = 24,
                            inkFraction: Double, inkBoxFraction: Double) -> Bool {
        let c = r.clamped(width: width, height: height)
        let mx = Int(Double(c.width) * margin), my = Int(Double(c.height) * margin)
        let inner = PixelRect(x: c.x + mx, y: c.y + my, width: c.width - 2 * mx, height: c.height - 2 * my)
        guard inner.area > 0 else { return true }
        var hist = [Int](repeating: 0, count: 256)
        for y in inner.y..<inner.maxY {
            let row = y * width
            for x in inner.x..<inner.maxX { hist[Int(pixels[row + x])] += 1 }
        }
        var median = 0, seen = 0
        while seen + hist[median] <= inner.area / 2 { seen += hist[median]; median += 1 }
        var ink = 0, minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
        for y in inner.y..<inner.maxY {
            let row = y * width
            for x in inner.x..<inner.maxX where abs(Int(pixels[row + x]) - median) > inkDelta {
                ink += 1
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        let area = Double(inner.area)
        if Double(ink) < inkFraction * area { return true }
        return Double((maxX - minX + 1) * (maxY - minY + 1)) < inkBoxFraction * area
    }

    /// Population mean and standard deviation over `r` (clamped). Empty rect → (0, 0).
    public func meanAndStd(_ r: PixelRect) -> (mean: Double, std: Double) {
        let c = r.clamped(width: width, height: height)
        guard c.area > 0 else { return (0, 0) }
        var sum = 0, sumSq = 0
        for y in c.y..<c.maxY {
            let row = y * width
            for x in c.x..<c.maxX {
                let v = Int(pixels[row + x])
                sum += v
                sumSq += v * v
            }
        }
        let n = Double(c.area)
        let mean = Double(sum) / n
        let variance = max(Double(sumSq) / n - mean * mean, 0)
        return (mean, variance.squareRoot())
    }
}
