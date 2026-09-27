// Draws the app icon (1024×1024 PNG): a macOS-style squircle, a paper page with a folded
// corner, and camera viewfinder brackets around it. Run: swift tools/make_icon.swift out.png
import AppKit

let size: CGFloat = 1024
let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png")

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

// Background squircle (Apple grid: 824 px body centred in 1024 canvas), with a drop shadow.
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let squircle = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor.black.withAlphaComponent(0.35).cgColor)
ctx.addPath(squircle)
ctx.setFillColor(NSColor.black.cgColor)
ctx.fillPath()
ctx.restoreGState()
ctx.saveGState()
ctx.addPath(squircle)
ctx.clip()
let bg = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                    colors: [NSColor(calibratedRed: 0.10, green: 0.13, blue: 0.20, alpha: 1).cgColor,
                             NSColor(calibratedRed: 0.05, green: 0.36, blue: 0.47, alpha: 1).cgColor] as CFArray,
                    locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: 100), end: CGPoint(x: 0, y: 924), options: [])
ctx.restoreGState()

// Page with folded top-right corner.
let page = CGRect(x: 322, y: 250, width: 380, height: 500)
let fold: CGFloat = 96
let pagePath = CGMutablePath()
pagePath.move(to: CGPoint(x: page.minX, y: page.minY))
pagePath.addLine(to: CGPoint(x: page.maxX, y: page.minY))
pagePath.addLine(to: CGPoint(x: page.maxX, y: page.maxY - fold))
pagePath.addLine(to: CGPoint(x: page.maxX - fold, y: page.maxY))
pagePath.addLine(to: CGPoint(x: page.minX, y: page.maxY))
pagePath.closeSubpath()
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 18, color: NSColor.black.withAlphaComponent(0.4).cgColor)
ctx.addPath(pagePath)
ctx.setFillColor(NSColor(calibratedRed: 0.98, green: 0.95, blue: 0.86, alpha: 1).cgColor)
ctx.fillPath()
ctx.restoreGState()
let foldPath = CGMutablePath()
foldPath.move(to: CGPoint(x: page.maxX - fold, y: page.maxY))
foldPath.addLine(to: CGPoint(x: page.maxX - fold, y: page.maxY - fold))
foldPath.addLine(to: CGPoint(x: page.maxX, y: page.maxY - fold))
foldPath.closeSubpath()
ctx.addPath(foldPath)
ctx.setFillColor(NSColor(calibratedRed: 0.85, green: 0.80, blue: 0.68, alpha: 1).cgColor)
ctx.fillPath()

// Text lines + a "panel" block on the page.
ctx.setFillColor(NSColor(calibratedRed: 0.55, green: 0.52, blue: 0.47, alpha: 1).cgColor)
for (i, w) in [220, 250, 190].enumerated() {
    ctx.fill(CGRect(x: page.minX + 50, y: page.maxY - 150 - CGFloat(i) * 44, width: CGFloat(w), height: 20))
}
ctx.setFillColor(NSColor(calibratedRed: 0.86, green: 0.36, blue: 0.24, alpha: 1).cgColor)
ctx.fill(CGRect(x: page.minX + 50, y: page.minY + 50, width: page.width - 100, height: 190))

// Viewfinder brackets around the page.
let vf = page.insetBy(dx: -62, dy: -62)
let arm: CGFloat = 110
ctx.setStrokeColor(NSColor(calibratedRed: 0.35, green: 0.90, blue: 0.95, alpha: 1).cgColor)
ctx.setLineWidth(30)
ctx.setLineCap(.round)
ctx.setLineJoin(.round)
for (cx, cy, dx, dy) in [(vf.minX, vf.minY, 1.0, 1.0), (vf.maxX, vf.minY, -1.0, 1.0),
                         (vf.minX, vf.maxY, 1.0, -1.0), (vf.maxX, vf.maxY, -1.0, -1.0)] {
    ctx.move(to: CGPoint(x: cx, y: cy + dy * arm))
    ctx.addLine(to: CGPoint(x: cx, y: cy))
    ctx.addLine(to: CGPoint(x: cx + dx * arm, y: cy))
}
ctx.strokePath()

NSGraphicsContext.current = nil
try! rep.representation(using: .png, properties: [:])!.write(to: out)
print("wrote \(out.path)")
