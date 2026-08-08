// Draws the app icon as a PNG. Run via: swift Tools/makeicon.swift <output.png> <size>
import AppKit

let args = CommandLine.arguments
let outputPath = args.count > 1 ? args[1] : "icon.png"
let side = args.count > 2 ? Double(args[2]) ?? 1024 : 1024

let size = NSSize(width: side, height: side)
let image = NSImage(size: size)
image.lockFocus()

guard let context = NSGraphicsContext.current?.cgContext else { exit(1) }
let s = side / 1024.0

// Rounded squircle background with a vertical gradient.
let inset = 84.0 * s
let bounds = CGRect(x: inset, y: inset, width: side - inset * 2, height: side - inset * 2)
let background = NSBezierPath(roundedRect: bounds, xRadius: 200 * s, yRadius: 200 * s)
context.saveGState()
background.addClip()
let gradient = NSGradient(colors: [
    NSColor(calibratedRed: 0.12, green: 0.14, blue: 0.20, alpha: 1),
    NSColor(calibratedRed: 0.05, green: 0.06, blue: 0.09, alpha: 1),
])
gradient?.draw(in: bounds, angle: -90)

// Film-strip perforations down both edges.
NSColor(calibratedWhite: 1, alpha: 0.10).setFill()
let holeW = 46.0 * s, holeH = 62.0 * s, gap = 40.0 * s
var y = bounds.minY + 46 * s
while y + holeH < bounds.maxY {
    for x in [bounds.minX + 34 * s, bounds.maxX - 34 * s - holeW] {
        NSBezierPath(roundedRect: CGRect(x: x, y: y, width: holeW, height: holeH),
                     xRadius: 12 * s, yRadius: 12 * s).fill()
    }
    y += holeH + gap
}

// Crop marks: two overlapping L-shaped brackets.
let cx = bounds.midX, cy = bounds.midY
let arm = 210.0 * s, thick = 40.0 * s, offset = 62.0 * s

func bracket(originX: CGFloat, originY: CGFloat, flipX: CGFloat, flipY: CGFloat, color: NSColor) {
    color.setFill()
    let path = NSBezierPath()
    path.move(to: CGPoint(x: originX, y: originY))
    path.line(to: CGPoint(x: originX + arm * flipX, y: originY))
    path.line(to: CGPoint(x: originX + arm * flipX, y: originY + thick * flipY))
    path.line(to: CGPoint(x: originX + thick * flipX, y: originY + thick * flipY))
    path.line(to: CGPoint(x: originX + thick * flipX, y: originY + arm * flipY))
    path.line(to: CGPoint(x: originX, y: originY + arm * flipY))
    path.close()
    path.fill()
}

bracket(originX: cx - offset - arm + thick, originY: cy + offset + arm - thick,
        flipX: 1, flipY: -1, color: NSColor(calibratedRed: 0.36, green: 0.72, blue: 1.0, alpha: 1))
bracket(originX: cx + offset + arm - thick, originY: cy - offset - arm + thick,
        flipX: -1, flipY: 1, color: NSColor(calibratedRed: 1.0, green: 0.62, blue: 0.31, alpha: 1))

// Play triangle in the middle.
NSColor(calibratedWhite: 1, alpha: 0.92).setFill()
let play = NSBezierPath()
let ps = 58.0 * s
play.move(to: CGPoint(x: cx - ps * 0.55, y: cy - ps))
play.line(to: CGPoint(x: cx + ps * 0.85, y: cy))
play.line(to: CGPoint(x: cx - ps * 0.55, y: cy + ps))
play.close()
play.fill()

context.restoreGState()
image.unlockFocus()

guard
    let tiff = image.tiffRepresentation,
    let rep = NSBitmapImageRep(data: tiff),
    let png = rep.representation(using: .png, properties: [:])
else { exit(1) }

try? png.write(to: URL(fileURLWithPath: outputPath))
