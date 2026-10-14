import AppKit
import CoreGraphics
import Foundation

// The app in one picture: a screen frame with a rounded facecam square in the
// corner and a record dot. Drawn in a 1024 space and scaled, so it stays
// legible down to 16pt.
func drawIcon(into ctx: CGContext, size: CGFloat) {
    let s = size / 1024
    ctx.scaleBy(x: s, y: s)

    let bgTop = CGColor(red: 0.13, green: 0.15, blue: 0.23, alpha: 1)
    let bgBottom = CGColor(red: 0.07, green: 0.08, blue: 0.13, alpha: 1)
    let screen = CGColor(red: 0.18, green: 0.22, blue: 0.33, alpha: 1)
    let teal = CGColor(red: 0.22, green: 0.78, blue: 0.72, alpha: 1)
    let tealSoft = CGColor(red: 0.22, green: 0.78, blue: 0.72, alpha: 0.35)
    let red = CGColor(red: 0.92, green: 0.34, blue: 0.30, alpha: 1)

    // macOS leaves breathing room around the squircle.
    let inset: CGFloat = 90
    let box = CGRect(x: inset, y: inset, width: 1024 - inset * 2, height: 1024 - inset * 2)
    let squircle = CGPath(roundedRect: box, cornerWidth: 200, cornerHeight: 200, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 34,
                  color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.28))
    ctx.addPath(squircle)
    ctx.setFillColor(bgBottom)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.clip()

    // Vertical gradient over the card.
    let colors = [bgTop, bgBottom] as CFArray
    if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                 colors: colors, locations: [0, 1]) {
        ctx.drawLinearGradient(gradient,
                               start: CGPoint(x: 512, y: box.maxY),
                               end: CGPoint(x: 512, y: box.minY),
                               options: [])
    }

    // The "screen": a 16:9-ish rounded rect, centred, slightly high.
    let screenRect = CGRect(x: 190, y: 330, width: 644, height: 400)
    let screenPath = CGPath(roundedRect: screenRect, cornerWidth: 40, cornerHeight: 40, transform: nil)
    ctx.addPath(screenPath)
    ctx.setFillColor(screen)
    ctx.fillPath()

    // The facecam: rounded square hugging the screen's bottom-right, teal.
    let cam = CGRect(x: screenRect.maxX - 210, y: screenRect.minY - 60, width: 230, height: 230)
    let camPath = CGPath(roundedRect: cam, cornerWidth: 56, cornerHeight: 56, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 40, color: tealSoft)
    ctx.addPath(camPath)
    ctx.setFillColor(teal)
    ctx.fillPath()
    ctx.restoreGState()

    // Record dot, top-left of the screen.
    if size >= 32 {
        ctx.setFillColor(red)
        ctx.fillEllipse(in: CGRect(x: screenRect.minX + 36, y: screenRect.maxY - 72, width: 44, height: 44))
    }

    ctx.restoreGState()
}

// --- iconset writer ---------------------------------------------------------

let args = CommandLine.arguments
guard args.count == 2 else {
    FileHandle.standardError.write("usage: make-icon.swift <output.iconset>\n".data(using: .utf8)!)
    exit(1)
}
let outDir = URL(fileURLWithPath: args[1], isDirectory: true)
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

let sizes: [(name: String, px: CGFloat)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

for (name, px) in sizes {
    let w = Int(px), h = Int(px)
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                              bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { continue }
    drawIcon(into: ctx, size: px)
    guard let image = ctx.makeImage() else { continue }
    let rep = NSBitmapImageRep(cgImage: image)
    guard let png = rep.representation(using: .png, properties: [:]) else { continue }
    try png.write(to: outDir.appendingPathComponent("\(name).png"))
}
print("iconset written to \(outDir.path)")
