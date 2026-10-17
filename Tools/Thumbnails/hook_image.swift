// Draws a thumbnail's hook picture: two lines of words in Inter Bold, a brand's logo as the
// last word (trimmed to its own shape, matched to the cap height), and a row of logo badges
// (a white pill with the logo and its name). Give it to the thumbnail maker as `image`, with
// `imageSize` 1.6. The logos come from the app's logo library.
//
// Run from the repository's root:
//   swift Tools/Thumbnails/hook_image.swift OUT.png "HOW I BUILT" "MY OWN" Mobbin Supabase Claude Figma
// Arguments: the output, the first line, the second line, the logo after the second line
// ("-" for none), then up to three badges. Each name is a file NAME.png in the logo library.
import AppKit
import CoreText

let args = CommandLine.arguments
guard args.count >= 5 else {
    print("usage: swift Tools/Thumbnails/hook_image.swift OUT.png LINE1 LINE2 LOGO|- [BADGE ...]"); exit(2)
}
let out = URL(fileURLWithPath: args[1]), line1 = args[2], line2 = args[3], logo = args[4]
let badges = Array(args.dropFirst(5).prefix(3))
let logos = (NSString(string: "~/Library/Application Support/YamVideo/Logos").expandingTildeInPath as String)
let fontURL = URL(fileURLWithPath: "Resources/Graphics/fonts/Inter-700-latin.woff2")

var error: Unmanaged<CFError>?
CTFontManagerRegisterFontsForURL(fontURL as CFURL, .process, &error)
guard let bold = NSFont(name: "Inter-Bold", size: 10) ?? NSFont(name: "Inter Bold", size: 10) else {
    print("Inter Bold did not load. Run from the repository's root."); exit(1)
}
func inter(_ size: Double) -> NSFont { NSFont(descriptor: bold.fontDescriptor, size: size)! }
let ink = NSColor(srgbRed: 0x12 / 255, green: 0x14 / 255, blue: 0x17 / 255, alpha: 1)
let edge = NSColor(srgbRed: 0xDD / 255, green: 0xE0 / 255, blue: 0xE5 / 255, alpha: 1)

func image(_ name: String) -> NSImage {
    guard let i = NSImage(contentsOfFile: "\(logos)/\(name).png") else { print("missing logo \(name).png in \(logos)"); exit(1) }
    return i
}
/// The part of an image that is not transparent, in its own points.
func opaqueRect(_ img: NSImage) -> NSRect {
    guard let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return NSRect(origin: .zero, size: img.size) }
    let w = cg.width, h = cg.height
    var pixels = [UInt8](repeating: 0, count: w * h * 4)
    let ctx = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
    var x0 = w, x1 = -1, y0 = h, y1 = -1
    for y in 0..<h { for x in 0..<w where pixels[(y * w + x) * 4 + 3] > 8 { x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y); y1 = max(y1, y) } }
    guard x1 >= x0 else { return NSRect(origin: .zero, size: img.size) }
    let k = img.size.width / Double(w)
    // Rows run from the top in the buffer; NSImage counts from the bottom.
    return NSRect(x: Double(x0) * k, y: Double(h - 1 - y1) * k, width: Double(x1 - x0 + 1) * k, height: Double(y1 - y0 + 1) * k)
}

let font = inter(150)
func words(_ t: String) -> NSAttributedString { NSAttributedString(string: t, attributes: [.font: font, .foregroundColor: ink, .kern: -3]) }
let label = inter(58)
let badgeTexts = badges.map { NSAttributedString(string: $0, attributes: [.font: label, .foregroundColor: ink, .kern: -1]) }
let badgeWidths = badgeTexts.map { 24 + 96 + 22 + $0.size().width + 40 }
let mark = logo == "-" ? nil : image(logo)
let markBox = mark.map(opaqueRect)
let markH = font.capHeight * 1.12
let markW = markBox.map { markH * $0.width / $0.height } ?? 0
let second = words(line2)
let W = ceil(max(words(line1).size().width, second.size().width + (mark == nil ? 0 : 40 + markW),
                 badgeWidths.reduce(0, +) + 26 * Double(max(0, badges.count - 1))))
let H = badges.isEmpty ? 360.0 : 560.0

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W), pixelsHigh: Int(H), bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSGraphicsContext.current?.imageInterpolation = .high
NSColor.clear.set(); NSRect(x: 0, y: 0, width: W, height: H).fill(using: .copy)
func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> NSRect { NSRect(x: x, y: H - y - h, width: w, height: h) }

// Two lines of words; the logo after the second, its height matched to the capitals.
let first = 150.0, gap = 172.0
words(line1).draw(at: NSPoint(x: 0, y: H - first + font.descender))
second.draw(at: NSPoint(x: 0, y: H - (first + gap) + font.descender))
if let mark, let markBox {
    let capTop = first + gap - font.capHeight
    mark.draw(in: rect(second.size().width + 40, capTop - (markH - font.capHeight) / 2, markW, markH),
              from: markBox, operation: .sourceOver, fraction: 1)
}

// The badges.
var x = 0.0
for (i, name) in badges.enumerated() {
    let r = rect(x, 412, badgeWidths[i], 136)
    let pill = NSBezierPath(roundedRect: r, xRadius: 68, yRadius: 68)
    NSColor.white.setFill(); pill.fill(); edge.setStroke(); pill.lineWidth = 3; pill.stroke()
    let img = image(name), box = rect(x + 28, 432, 96, 96)
    let k = min(box.width / img.size.width, box.height / img.size.height)
    img.draw(in: NSRect(x: box.midX - img.size.width * k / 2, y: box.midY - img.size.height * k / 2,
                        width: img.size.width * k, height: img.size.height * k))
    badgeTexts[i].draw(at: NSPoint(x: x + 24 + 96 + 22, y: r.midY - badgeTexts[i].size().height / 2))
    x += badgeWidths[i] + 26
}

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: out)
print("wrote \(out.path) \(Int(W))×\(Int(H))")
