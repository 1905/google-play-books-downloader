import CoreGraphics
import Foundation
@testable import ScreenshoterCore

/// Synthetic image helpers for tests.
enum TestImages {
    static func solid(_ w: Int, _ h: Int, _ value: UInt8) -> GrayImage {
        GrayImage(width: w, height: h, fill: value)
    }

    /// Fills `rect` (clamped to the image) with `value`.
    static func drawRect(into image: inout GrayImage, rect: PixelRect, value: UInt8) {
        let r = rect.clamped(width: image.width, height: image.height)
        for y in r.y..<r.maxY {
            for x in r.x..<r.maxX {
                image[x, y] = value
            }
        }
    }

    /// "Comic-like" page: random 8×8 blocks of 0/128/255 from a seeded LCG.
    static func noisePage(_ w: Int, _ h: Int, seed: UInt64) -> GrayImage {
        var img = GrayImage(width: w, height: h, fill: 0)
        drawNoise(into: &img, rect: img.bounds, seed: seed)
        return img
    }

    /// Draws a noise page of `block`×`block` cells into `rect` of `image`. Cells are aligned to `rect`'s origin.
    static func drawNoise(into image: inout GrayImage, rect: PixelRect, seed: UInt64, block: Int = 8) {
        var state = seed &* 6364136223846793005 &+ 1442695040888963407
        let levels: [UInt8] = [0, 128, 255]
        let r = rect.clamped(width: image.width, height: image.height)
        var by = r.y
        while by < r.maxY {
            var bx = r.x
            while bx < r.maxX {
                state = state &* 6364136223846793005 &+ 1442695040888963407
                let v = levels[Int((state >> 33) % 3)]
                for y in by..<min(by + block, r.maxY) {
                    for x in bx..<min(bx + block, r.maxX) {
                        image[x, y] = v
                    }
                }
                bx += block
            }
            by += block
        }
    }

    static func cgImage(from image: GrayImage) -> CGImage {
        let data = Data(image.pixels) as CFData
        let provider = CGDataProvider(data: data)!
        return CGImage(width: image.width, height: image.height, bitsPerComponent: 8, bitsPerPixel: 8,
                       bytesPerRow: image.width, space: CGColorSpaceCreateDeviceGray(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    static func rgbCGImage(_ w: Int, _ h: Int, fill: (r: UInt8, g: UInt8, b: UInt8)) -> CGImage {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(red: CGFloat(fill.r) / 255, green: CGFloat(fill.g) / 255,
                         blue: CGFloat(fill.b) / 255, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()!
    }
}
