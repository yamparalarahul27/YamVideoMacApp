import AppKit
import CoreGraphics
import Foundation
import Vision

// The phone check (docs/plans/thumbnail-science.md, part 1): the thumbnail at the size of
// a phone's YouTube home feed and search list, and what does not read there in 0.5 s:
// letters too small, too many words, low contrast, a face too small. The thumbnail page
// measures its words; Apple Vision finds the face and the words in the picture.

/// Where YouTube shows a thumbnail on a phone, in points of an iPhone's 390 pt wide screen.
enum PhoneSize: String, Codable, CaseIterable, Identifiable {
    /// The home feed: the thumbnail fills the screen's width.
    case homeFeed
    /// A search list row: a small thumbnail beside the title. Up next, the history and
    /// playlists use the same size.
    case searchList

    var id: String { rawValue }
    var width: Double { self == .homeFeed ? 390 : 168 }
    var height: Double { width * 9 / 16 }
    var label: String { self == .homeFeed ? "Home feed" : "Search list" }
    /// Points on the phone for a length in stage pixels (the design is 1920 px wide).
    func points(_ pixels: Double) -> Double { pixels * width / 1920 }
    /// Stage pixels for a length in points on the phone.
    func pixels(_ points: Double) -> Double { points * 1920 / width }
}

/// What the thumbnail page measured of a drawn design (`YamGraphics.thumbnailLayout()`),
/// in stage pixels of 1920×1080.
struct ThumbnailLayout: Codable, Equatable {
    struct Box: Codable, Equatable {
        var x: Double, y: Double, w: Double, h: Double
        init(_ rect: CGRect) { x = rect.minX; y = rect.minY; w = rect.width; h = rect.height }
        var rect: CGRect { CGRect(x: x, y: y, width: w, height: h) }
    }

    /// A run of words with one look: the tag, plain title words, accent words, or a line of
    /// words in the picture beside the title.
    struct Run: Codable, Equatable {
        enum Kind: String, Codable { case tag, title, accent, picture }
        var kind: Kind
        var text: String
        /// One box for each line the run is on.
        var boxes: [Box]
        /// The letters' size: the font's size, or for a line in the picture, the height of
        /// the line Apple Vision found.
        var size: Double
        /// #RRGGBB; nil for words in the picture.
        var color: String?
        /// The run's own band (the tag, highlighted words); nil when the picture shows behind.
        var background: String?
    }

    /// How the page moved the cut-out speaker: scaled about the origin, then shifted in x.
    struct Move: Codable, Equatable {
        var scale: Double, shift: Double, originX: Double, originY: Double
        func apply(_ rect: CGRect) -> CGRect {
            CGRect(x: originX + (rect.minX - originX) * scale + shift, y: originY + (rect.minY - originY) * scale,
                   width: rect.width * scale, height: rect.height * scale)
        }
    }

    var titleSize: Double
    var runs: [Run]
    var picture: Box?
    /// Nil when no cut-out speaker is drawn.
    var speaker: Move?
    /// The frame shows sharp behind the speaker and the words: not hidden, not blurred.
    var frame = true
}

/// The phone check of one design: what does not read on a phone in 0.5 s.
struct PhoneCheck: Equatable {
    struct Finding: Codable, Equatable, Identifiable {
        enum Kind: String, Codable, CaseIterable { case textSize, words, contrast, face }
        /// fails: does not read in 0.5 s. weak: reads, but not at a glance.
        enum Level: String, Codable { case fails, weak }
        var kind: Kind
        var level: Level
        /// Where it applies.
        var sizes: [PhoneSize]
        /// One short line, like "Title too small: 8.9 pt in the search list".
        var summary: String
        /// The summary in full, with the limit and what to do.
        var message: String
        var id: String { "\(kind.rawValue)-\(level.rawValue)-\(sizes.map(\.rawValue).joined(separator: "+"))-\(message)" }
    }

    var findings: [Finding]
    /// The words of the tag, the title and the picture.
    var words: Int
    /// The title's letter size in stage pixels.
    var titleSize: Double
    /// The face in the thumbnail, in stage pixels; nil when Apple Vision finds none.
    var face: CGRect?

    var reads: Bool { findings.isEmpty }
    var fails: Int { findings.filter { $0.level == .fails }.count }

    // The limits. Change them here after the owner tries them on real thumbnails.
    /// Letter size in points on the phone: this or more reads in 0.5 s; less than `smallest` does not read.
    static let letterLimits = (reads: 12.0, smallest: 9.0)
    /// Words in the whole thumbnail: up to `reads` read in 0.5 s; more than `most` do not.
    static let wordLimits = (reads: 5, most: 8)
    /// Contrast of words against what is behind them, as WCAG measures it (1 to 21).
    static let contrastLimits = (reads: 4.5, lowest: 3.0)
    /// The face's height in points on the phone.
    static let faceLimits = (reads: 24.0, smallest: 16.0)

    /// The check, from what the page measured. `contrasts` has one value for each run of
    /// `layout` (nil when it cannot be measured); `face` is in stage pixels. `faceHidden`:
    /// the frame has a face, but the design does not show it.
    static func make(layout: ThumbnailLayout, contrasts: [Double?], face: CGRect?, faceHidden: Bool = false) -> PhoneCheck {
        var findings: [Finding] = []
        let runs = layout.runs.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        // Letters: one entry for the tag, one for the title (its runs share a size) and one
        // for the smallest line of the picture. The tag has a fixed size and is a small
        // label, so at most it is weak.
        if let tag = runs.first(where: { $0.kind == .tag }) {
            findings += bySize(.textSize) { size in
                let points = size.points(tag.size)
                guard points < letterLimits.reads else { return nil }
                return (.weak, "Tag too small: \(format(points)) pt in the \(size.label.lowercased())",
                        "The tag \(quoted(tag.text)) is \(format(points)) pt high in the \(size.label.lowercased()): too small to "
                        + "read at a glance. The tag has a fixed size, so keep the important words in the title.")
            }
        }
        var parts: [(short: String, name: String, size: Double, advice: String)] = []
        if runs.contains(where: { $0.kind == .title || $0.kind == .accent }) {
            parts.append(("Title", "The title", layout.titleSize, "Use fewer or shorter words, or a smaller picture: the title then grows to fill its space."))
        }
        if let line = runs.filter({ $0.kind == .picture }).min(by: { $0.size < $1.size }) {
            parts.append(("Picture words", "\(quoted(line.text)) in the picture", line.size, "Make the picture larger, or put fewer and bigger words in it."))
        }
        for part in parts {
            findings += bySize(.textSize) { size in
                let points = size.points(part.size)
                let place = "\(format(points)) pt in the \(size.label.lowercased())"
                if points < letterLimits.smallest {
                    return (.fails, "\(part.short) too small: " + place, "\(part.name) is \(format(points)) pt high in the \(size.label.lowercased()). Letters smaller than "
                            + "\(format(letterLimits.smallest)) pt (\(Int(size.pixels(letterLimits.smallest).rounded(.up))) px of the design) "
                            + "do not read in 0.5 s. " + part.advice)
                }
                if points < letterLimits.reads {
                    return (.weak, "\(part.short) small: " + place, "\(part.name) is \(format(points)) pt high in the \(size.label.lowercased()). It reads, but not at a "
                            + "glance: \(format(letterLimits.reads)) pt (\(Int(size.pixels(letterLimits.reads).rounded(.up))) px of the design) "
                            + "or more reads in 0.5 s.")
                }
                return nil
            }
        }

        let count = runs.reduce(0) { $0 + wordCount(in: $1.text) }
        if count > wordLimits.most {
            findings.append(Finding(kind: .words, level: .fails, sizes: PhoneSize.allCases, summary: "Too many words: \(count)",
                                    message: "\(count) words. A viewer reads about \(wordLimits.reads) words in 0.5 s. Remove words, or move them to the title."))
        } else if count > wordLimits.reads {
            findings.append(Finding(kind: .words, level: .weak, sizes: PhoneSize.allCases, summary: "Many words: \(count)",
                                    message: "\(count) words. Up to \(wordLimits.reads) words read in 0.5 s."))
        }

        // Contrast: the worst run of each kind, so a long title gives one finding.
        var worst: [ThumbnailLayout.Run.Kind: (run: ThumbnailLayout.Run, ratio: Double)] = [:]
        for (run, ratio) in zip(layout.runs, contrasts) {
            guard let ratio, !run.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            if worst[run.kind].map({ ratio < $0.ratio }) ?? true { worst[run.kind] = (run, ratio) }
        }
        for kind in [ThumbnailLayout.Run.Kind.tag, .title, .accent, .picture] {
            guard let (run, ratio) = worst[kind], ratio < contrastLimits.reads else { continue }
            let name: String
            switch kind {
            case .tag: name = "the tag \(quoted(run.text))"
            case .title: name = "the title words \(quoted(run.text))"
            case .accent: name = "the coloured words \(quoted(run.text))"
            case .picture: name = "\(quoted(run.text)) in the picture"
            }
            let advice = run.background != nil ? " Use another accent colour."
                : run.kind == .accent ? " Turn on Highlight, or use a darker accent."
                : " Use a plainer background behind the words."
            let summary = "Low contrast: " + (kind == .tag ? "tag" : quoted(run.text, limit: 20)) + " \(format(ratio)):1"
            if ratio < contrastLimits.lowest {
                findings.append(Finding(kind: .contrast, level: .fails, sizes: PhoneSize.allCases, summary: summary,
                                        message: "Contrast of \(name): \(format(ratio)):1. Less than \(format(contrastLimits.lowest)):1 "
                                        + "does not read in 0.5 s." + advice))
            } else {
                findings.append(Finding(kind: .contrast, level: .weak, sizes: PhoneSize.allCases, summary: summary,
                                        message: "Contrast of \(name): \(format(ratio)):1. \(format(contrastLimits.reads)):1 or more reads at a glance."))
            }
        }

        if let face {
            findings += bySize(.face) { size in
                let points = face.height * size.height / 1080
                let place = "\(format(points)) pt in the \(size.label.lowercased())"
                if points < faceLimits.smallest {
                    return (.fails, "Face too small: " + place, "The face is \(format(points)) pt high in the \(size.label.lowercased()). A face smaller than "
                            + "\(format(faceLimits.smallest)) pt does not read in 0.5 s. Make the speaker larger, or pick a closer frame.")
                }
                if points < faceLimits.reads {
                    return (.weak, "Face small: " + place, "The face is \(format(points)) pt high in the \(size.label.lowercased()). "
                            + "\(format(faceLimits.reads)) pt or more reads at a glance.")
                }
                return nil
            }
        } else if faceHidden {
            findings.append(Finding(kind: .face, level: .weak, sizes: PhoneSize.allCases, summary: "Face does not show",
                                    message: "The face does not show. A face draws the eye first: cut the speaker out, or use a background that shows the frame."))
        } else {
            findings.append(Finding(kind: .face, level: .weak, sizes: PhoneSize.allCases, summary: "No face found",
                                    message: "No face found. A face draws the eye first: pick a frame with a clear face."))
        }

        let order = Finding.Kind.allCases
        findings.sort { ($0.level == .fails ? 0 : 1, order.firstIndex(of: $0.kind)!) < ($1.level == .fails ? 0 : 1, order.firstIndex(of: $1.kind)!) }
        return PhoneCheck(findings: findings, words: count, titleSize: layout.titleSize, face: face)
    }

    /// One finding for each size where `judge` finds a problem, or one for both sizes when
    /// the level is the same (with the search list's message: it is the smaller size).
    private static func bySize(_ kind: Finding.Kind, _ judge: (PhoneSize) -> (Finding.Level, String, String)?) -> [Finding] {
        let home = judge(.homeFeed), search = judge(.searchList)
        if let home, let search, home.0 == search.0 {
            return [Finding(kind: kind, level: search.0, sizes: PhoneSize.allCases, summary: search.1, message: search.2)]
        }
        return [home.map { Finding(kind: kind, level: $0.0, sizes: [.homeFeed], summary: $0.1, message: $0.2) },
                search.map { Finding(kind: kind, level: $0.0, sizes: [.searchList], summary: $0.1, message: $0.2) }].compactMap { $0 }
    }

    /// Words with a letter or a digit in them; the asterisks of accent words do not count.
    static func wordCount(in text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace || $0 == "*" }).filter { $0.contains(where: { $0.isLetter || $0.isNumber }) }.count
    }

    static func quoted(_ text: String, limit: Int = 28) -> String {
        let plain = text.replacingOccurrences(of: "\u{00A0}", with: " ").split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return "“" + (plain.count > limit ? String(plain.prefix(limit - 1)) + "…" : plain) + "”"
    }

    /// Whole numbers from 10, and below 10 one decimal unless it is whole.
    private static func format(_ value: Double) -> String {
        let tenths = (value * 10).rounded() / 10
        return value >= 10 || tenths == tenths.rounded() ? String(Int(value.rounded())) : String(format: "%.1f", tenths)
    }
}

// MARK: - Contrast

/// WCAG's measures of colour: relative luminance and the contrast ratio of two luminances.
enum Contrast {
    /// The relative luminance (0 to 1) of an sRGB colour with components 0 to 255.
    static func luminance(_ r: Double, _ g: Double, _ b: Double) -> Double {
        func linear(_ c: Double) -> Double {
            let v = c / 255
            return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
    }

    /// The luminance of #RRGGBB; nil when it is not a colour.
    static func luminance(hex: String?) -> Double? {
        guard let hex, hex.count == 7, hex.hasPrefix("#"), let value = UInt32(hex.dropFirst(), radix: 16) else { return nil }
        return luminance(Double((value >> 16) & 0xFF), Double((value >> 8) & 0xFF), Double(value & 0xFF))
    }

    /// From 1 (the same) to 21 (black and white).
    static func ratio(_ a: Double, _ b: Double) -> Double { (max(a, b) + 0.05) / (min(a, b) + 0.05) }

    /// Words of luminance `text` against the pixels behind them: the part of the background
    /// most like the words decides (the brightest tenth behind light words, the darkest
    /// tenth behind dark words). Nil without pixels.
    static func ratio(text: Double, behind samples: [Float]) -> Double? {
        guard !samples.isEmpty else { return nil }
        let sorted = samples.sorted()
        let median = Double(sorted[sorted.count / 2])
        let at = text > median ? Int(Double(sorted.count - 1) * 0.9) : Int(Double(sorted.count - 1) * 0.1)
        return ratio(text, Double(sorted[at]))
    }

    /// Words with unknown colours, inside a box of pixels: the pixels split into two groups
    /// at the threshold that separates them best (Otsu's method), and the contrast of the
    /// groups' means. Nil without pixels.
    static func split(_ samples: [Float]) -> Double? {
        guard samples.count >= 4 else { return nil }
        let bins = 64
        var histogram = [Int](repeating: 0, count: bins)
        for value in samples { histogram[min(bins - 1, max(0, Int(value * Float(bins))))] += 1 }
        let total = Double(samples.count)
        var best = (score: -1.0, low: 0.0, high: 0.0)
        for cut in 1..<bins {
            var lowCount = 0.0, lowSum = 0.0, highCount = 0.0, highSum = 0.0
            for bin in 0..<bins {
                let centre = (Double(bin) + 0.5) / Double(bins)
                if bin < cut { lowCount += Double(histogram[bin]); lowSum += centre * Double(histogram[bin]) }
                else { highCount += Double(histogram[bin]); highSum += centre * Double(histogram[bin]) }
            }
            guard lowCount > 0, highCount > 0 else { continue }
            let low = lowSum / lowCount, high = highSum / highCount
            let score = lowCount / total * highCount / total * (high - low) * (high - low)
            if score > best.score { best = (score, low, high) }
        }
        return best.score < 0 ? 1 : ratio(best.low, best.high)
    }
}

/// A picture's relative luminance at a smaller size, to sample behind the words.
struct LuminanceMap {
    let width: Int
    let height: Int
    /// Rows from the top.
    let values: [Float]

    init(width: Int, height: Int, values: [Float]) { self.width = width; self.height = height; self.values = values }

    /// `image` at `width` pixels wide (enough to sample a thumbnail's words).
    init(_ image: CGImage, width: Int = 640) {
        let height = max(1, Int((Double(width) * Double(image.height) / Double(max(1, image.width))).rounded()))
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        if let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                   space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        var table = [Float](repeating: 0, count: 256 * 3)
        for c in 0..<256 {
            table[c] = Float(Contrast.luminance(Double(c), 0, 0))
            table[256 + c] = Float(Contrast.luminance(0, Double(c), 0))
            table[512 + c] = Float(Contrast.luminance(0, 0, Double(c)))
        }
        var values = [Float](repeating: 0, count: width * height)
        for i in 0..<(width * height) {
            values[i] = table[Int(pixels[i * 4])] + table[256 + Int(pixels[i * 4 + 1])] + table[512 + Int(pixels[i * 4 + 2])]
        }
        self.init(width: width, height: height, values: values)
    }

    /// The values inside `rect`, given in stage pixels (1920 wide), but not where `mask`
    /// (of the same size) is set.
    func samples(in rect: CGRect, outside mask: LetterMask? = nil) -> [Float] {
        let k = Double(width) / 1920
        let x0 = max(0, Int((rect.minX * k).rounded(.down))), x1 = min(width, Int((rect.maxX * k).rounded(.up)))
        let y0 = max(0, Int((rect.minY * k).rounded(.down))), y1 = min(height, Int((rect.maxY * k).rounded(.up)))
        guard x1 > x0, y1 > y0 else { return [] }
        var found: [Float] = []
        found.reserveCapacity((x1 - x0) * (y1 - y0))
        for y in y0..<y1 {
            if let mask, mask.width == width, mask.height == height {
                for x in x0..<x1 where !mask.values[y * width + x] { found.append(values[y * width + x]) }
            } else {
                found.append(contentsOf: values[(y * width + x0)..<(y * width + x1)])
            }
        }
        return found
    }
}

/// Where the title's letters are, from a picture that draws them in pure magenta (#FF00FF)
/// without a shadow, at a `LuminanceMap`'s size: each letter pixel and its neighbours, so
/// the soft edges of the letters count as letters too.
struct LetterMask {
    let width: Int
    let height: Int
    /// Rows from the top.
    let values: [Bool]

    init(width: Int, height: Int, values: [Bool]) { self.width = width; self.height = height; self.values = values }

    init(_ image: CGImage, width: Int = 640) {
        let height = max(1, Int((Double(width) * Double(image.height) / Double(max(1, image.width))).rounded()))
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        if let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                   space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        // Magenta: red and blue well over green. A soft edge has some of it.
        var letter = [Bool](repeating: false, count: width * height)
        for i in 0..<(width * height) {
            let r = Int(pixels[i * 4]), g = Int(pixels[i * 4 + 1]), b = Int(pixels[i * 4 + 2])
            letter[i] = min(r, b) - g > 48
        }
        var grown = letter
        for y in 0..<height {
            for x in 0..<width where letter[y * width + x] {
                for dy in -1...1 { for dx in -1...1 {
                    let nx = x + dx, ny = y + dy
                    if nx >= 0, nx < width, ny >= 0, ny < height { grown[ny * width + nx] = true }
                } }
            }
        }
        self.init(width: width, height: height, values: grown)
    }
}

// MARK: - Measuring a drawn design

extension PhoneCheck {
    /// The largest face Apple Vision finds in `frame`, in its pixels (top-left origin).
    static func face(in frame: CGImage) -> CGRect? {
        let request = VNDetectFaceRectanglesRequest()
        try? VNImageRequestHandler(cgImage: frame).perform([request])
        guard let found = (request.results ?? []).max(by: { $0.boundingBox.height < $1.boundingBox.height }) else { return nil }
        let w = Double(frame.width), h = Double(frame.height), b = found.boundingBox
        return CGRect(x: b.minX * w, y: (1 - b.maxY) * h, width: b.width * w, height: b.height * h)
    }

    /// The lines of words Apple Vision reads in a picture, with their boxes as parts of the
    /// picture (0 to 1, top-left origin). Empty when the file cannot be read.
    static func words(in picture: URL) -> [(text: String, box: CGRect)] {
        guard let image = NSImage(contentsOf: picture)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return [] }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        try? VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { line in
            guard let text = line.topCandidates(1).first?.string, wordCount(in: text) > 0 else { return nil }
            let b = line.boundingBox
            return (text, CGRect(x: b.minX, y: 1 - b.maxY, width: b.width, height: b.height))
        }
    }

    /// The check of a drawn design: `image` is the thumbnail, `letters` the same with the
    /// title's letters in magenta (from `ThumbnailMaker.measure`), `face` the face in the
    /// frame's pixels (from `face(in:)`), and `pictureWords` the lines found in the picture
    /// beside the title (from `words(in:)`).
    static func make(layout: ThumbnailLayout, image: CGImage, letters: CGImage, face: CGRect?, frameWidth: Int,
                     pictureWords: [(text: String, box: CGRect)]) -> PhoneCheck {
        var layout = layout
        if let picture = layout.picture?.rect {
            for line in pictureWords {
                let box = CGRect(x: picture.minX + line.box.minX * picture.width, y: picture.minY + line.box.minY * picture.height,
                                 width: line.box.width * picture.width, height: line.box.height * picture.height)
                layout.runs.append(ThumbnailLayout.Run(kind: .picture, text: line.text, boxes: [ThumbnailLayout.Box(box)],
                                                       size: box.height, color: nil, background: nil))
            }
        }
        let full = LuminanceMap(image), mask = LetterMask(letters)
        let contrasts: [Double?] = layout.runs.map { run in
            let boxes = run.boxes.map(\.rect)
            if run.kind == .picture { return Contrast.split(boxes.flatMap { full.samples(in: $0) }) }
            guard let text = Contrast.luminance(hex: run.color) else { return nil }
            if let band = Contrast.luminance(hex: run.background) { return Contrast.ratio(text, band) }
            // What is round the letters in the finished picture: the shadow counts.
            return Contrast.ratio(text: text, behind: boxes.flatMap { full.samples(in: $0, outside: mask) })
        }
        // The face shows in the cut-out speaker, or in a sharp frame.
        let shows = layout.speaker != nil || layout.frame
        let k = 1920 / Double(max(1, frameWidth))
        let placed = face.map { CGRect(x: $0.minX * k, y: $0.minY * k, width: $0.width * k, height: $0.height * k) }
            .map { layout.speaker?.apply($0) ?? $0 }
        return make(layout: layout, contrasts: contrasts, face: shows ? placed : nil, faceHidden: face != nil && !shows)
    }

    /// Draws `design` and checks it, with Apple Vision for the face and the picture's words.
    @MainActor
    static func run(_ design: ThumbnailDesign, sources: ThumbnailMaker.Sources, accent: String) async throws -> (check: PhoneCheck, image: CGImage) {
        let drawn = try await ThumbnailMaker.measure(design, sources: sources, accent: accent)
        let frame = sources.frame, picture = design.image
        let found = await Task.detached(priority: .userInitiated) {
            (face(in: frame), picture.map { words(in: $0) } ?? [])
        }.value
        let check = make(layout: drawn.layout, image: drawn.image, letters: drawn.letters, face: found.0,
                         frameWidth: frame.width, pictureWords: found.1)
        return (check, drawn.image)
    }

    /// The thumbnail at both phone sizes side by side, at 2 pixels for each point, as a
    /// phone's screen shows them, with each size's name under it. For agents to look at.
    static func phonePicture(_ image: CGImage) -> CGImage? {
        let scale = 2.0, gap = 16.0 * scale, label = 22.0 * scale
        let home = CGSize(width: PhoneSize.homeFeed.width * scale, height: PhoneSize.homeFeed.height * scale)
        let search = CGSize(width: PhoneSize.searchList.width * scale, height: PhoneSize.searchList.height * scale)
        let width = Int(gap * 3 + home.width + search.width), height = Int(gap * 2 + home.height + label)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(CGColor(gray: 0.95, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        let top = Double(height) - gap
        let homeBox = CGRect(x: gap, y: top - home.height, width: home.width, height: home.height)
        let searchBox = CGRect(x: gap * 2 + home.width, y: top - search.height, width: search.width, height: search.height)
        for box in [homeBox, searchBox] {
            context.saveGState()
            context.addPath(CGPath(roundedRect: box, cornerWidth: 8 * scale, cornerHeight: 8 * scale, transform: nil))
            context.clip()
            context.draw(image, in: box)
            context.restoreGState()
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        let font = NSFont.systemFont(ofSize: 13 * scale, weight: .medium)
        for (size, box) in [(PhoneSize.homeFeed, homeBox), (.searchList, searchBox)] {
            let text = "\(size.label), \(Int(size.width)) × \(Int(size.height)) pt" as NSString
            text.draw(at: CGPoint(x: box.minX, y: box.minY - label + 4 * scale),
                      withAttributes: [.font: font, .foregroundColor: NSColor(white: 0.25, alpha: 1)])
        }
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()
    }
}
