import AppKit
import CoreImage
import Foundation
import Vision
import WebKit

// The thumbnail maker (graphics track G3, docs/plans/graphics-track.md): a frame of the
// recording, the speaker cut out with Apple Vision, and a big title, an accent tag and an
// optional product photo beside them, drawn by the graphics engine at 1280×720.

/// How a thumbnail is made, kept with the publish details so it can be made again.
struct ThumbnailDesign: Codable, Equatable {
    enum Side: String, Codable, CaseIterable, Identifiable {
        case auto, left, right
        var id: String { rawValue }
        var label: String { self == .auto ? "Auto" : rawValue.capitalized }
    }
    /// Where the cut-out speaker goes: where the frame has them, or moved (and made smaller
    /// when it must) to the far side, clear of the title, the tag and the picture.
    enum Place: String, Codable, CaseIterable, Identifiable {
        case frame, clear
        var id: String { rawValue }
        var label: String { self == .frame ? "As recorded" : "Clear" }
    }
    enum Background: String, Codable, CaseIterable, Identifiable {
        /// frost: the frame as recorded, moved with the speaker, under a white blurred shade
        /// on the title side that fades out before the speaker, as the Ink layout's shade does.
        case frame, dim, blur, solid, white, frost
        var id: String { rawValue }
        var label: String {
            switch self {
            case .frame: return "As recorded"
            case .dim: return "Darker"
            case .blur: return "Blurred"
            case .solid: return "Plain"
            case .white: return "White"
            case .frost: return "White frost"
            }
        }
    }

    /// The frame, in edited-recording seconds.
    var time: Double = 0
    /// One to three lines; words between asterisks (*like this*) take the accent colour,
    /// or with `highlight` sit on a band of it in dark text.
    var title = ""
    var highlight = false
    /// A short label in the accent colour above the title.
    var tag = ""
    /// A colour like #F5C42C; nil uses the recording's graphics accent.
    var accent: String?
    /// A product photo or icon beside the title; a transparent PNG looks best.
    var image: URL?
    /// Cut the speaker out with Apple Vision, so the background can change behind them.
    var cutout = true
    /// A white outline round the cut-out, and its width in pixels of a 1920×1080 frame.
    var outline = true
    var outlineWidth = 9.0
    /// Where the title goes.
    var side = Side.auto
    var background = Background.dim
    /// How big the speaker is, growing up from the bottom of the frame: 1 to 1.6. With
    /// `place` clear, the speaker can be smaller, so that nothing overlaps.
    var zoom = 1.0
    var place = Place.frame
    /// How big the picture beside the title is: 1 to 1.6 times its usual size (at most
    /// 520×340 pixels of a 1920×1080 frame). The title gets smaller to make room.
    var imageSize = 1.0

    static let zooms = 1.0...1.6
    static let outlineWidths = 2.0...16.0
    static let imageSizes = 1.0...1.6
    static let titleLimit = 90
    static let tagLimit = 24

    init(time: Double = 0, title: String = "") { self.time = time; self.title = title }

    private enum CodingKeys: String, CodingKey {
        case time, title, tag, accent, image, cutout, outline, side, background, zoom, place, outlineWidth, highlight, imageSize
    }

    /// Missing keys keep their defaults; `image` is a plain path, as for the thumbnail.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = ThumbnailDesign()
        time = try c.decodeIfPresent(Double.self, forKey: .time) ?? defaults.time
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? defaults.title
        tag = try c.decodeIfPresent(String.self, forKey: .tag) ?? defaults.tag
        accent = try c.decodeIfPresent(String.self, forKey: .accent)
        image = try c.decodeIfPresent(String.self, forKey: .image).map { text in
            text.hasPrefix("file:") ? (URL(string: text) ?? URL(fileURLWithPath: text))
                : URL(fileURLWithPath: (text as NSString).expandingTildeInPath)
        }
        cutout = try c.decodeIfPresent(Bool.self, forKey: .cutout) ?? defaults.cutout
        outline = try c.decodeIfPresent(Bool.self, forKey: .outline) ?? defaults.outline
        side = try c.decodeIfPresent(Side.self, forKey: .side) ?? defaults.side
        background = try c.decodeIfPresent(Background.self, forKey: .background) ?? defaults.background
        zoom = try c.decodeIfPresent(Double.self, forKey: .zoom) ?? defaults.zoom
        place = try c.decodeIfPresent(Place.self, forKey: .place) ?? defaults.place
        outlineWidth = try c.decodeIfPresent(Double.self, forKey: .outlineWidth) ?? defaults.outlineWidth
        highlight = try c.decodeIfPresent(Bool.self, forKey: .highlight) ?? defaults.highlight
        imageSize = try c.decodeIfPresent(Double.self, forKey: .imageSize) ?? defaults.imageSize
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(time, forKey: .time)
        try c.encode(title, forKey: .title)
        try c.encode(tag, forKey: .tag)
        try c.encodeIfPresent(accent, forKey: .accent)
        try c.encodeIfPresent(image?.path, forKey: .image)
        try c.encode(cutout, forKey: .cutout)
        try c.encode(outline, forKey: .outline)
        try c.encode(side, forKey: .side)
        try c.encode(background, forKey: .background)
        try c.encode(zoom, forKey: .zoom)
        try c.encode(place, forKey: .place)
        try c.encode(outlineWidth, forKey: .outlineWidth)
        try c.encode(highlight, forKey: .highlight)
        if imageSize != 1 { try c.encode(imageSize, forKey: .imageSize) }
    }

    /// The first thing that cannot be stored, saying what is allowed; nil when all is well.
    var problem: String? {
        guard time.isFinite, time >= 0 else { return "The thumbnail's frame is seconds of the edited recording, from 0." }
        guard title.count <= Self.titleLimit, title.split(separator: "\n", omittingEmptySubsequences: false).count <= 3 else {
            return "A thumbnail title is at most \(Self.titleLimit) characters on up to 3 lines."
        }
        guard tag.count <= Self.tagLimit, !tag.contains(where: \.isNewline) else {
            return "A thumbnail tag is one line of at most \(Self.tagLimit) characters."
        }
        if let accent, !(accent.count == 7 && accent.hasPrefix("#") && accent.dropFirst().allSatisfy(\.isHexDigit)) {
            return "The thumbnail accent is a colour like #F5C42C."
        }
        guard zoom.isFinite, Self.zooms.contains(zoom) else { return "The speaker's size is from 1 to 1.6." }
        guard outlineWidth.isFinite, Self.outlineWidths.contains(outlineWidth) else { return "The outline's width is from 2 to 16 pixels." }
        guard imageSize.isFinite, Self.imageSizes.contains(imageSize) else { return "The picture's size is from 1 to 1.6." }
        if let image, !image.isFileURL { return "The thumbnail's image must be a local file." }
        return nil
    }
}

// MARK: - Cutting the speaker out

enum SpeakerCutout {
    /// The foreground (usually the speaker) of `frame` on transparency, the frame's size,
    /// and the box it fills; nil when Vision finds nothing in front.
    static func cut(_ frame: CGImage) throws -> (image: CGImage, box: CGRect)? {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: frame)
        try handler.perform([request])
        guard let result = request.results?.first, !result.allInstances.isEmpty else { return nil }
        let buffer = try result.generateMaskedImage(ofInstances: result.allInstances, from: handler, croppedToInstancesExtent: false)
        let picture = CIImage(cvPixelBuffer: buffer)
        let context = CIContext()
        guard let image = context.createCGImage(picture, from: picture.extent, format: .RGBA8,
                                                colorSpace: frame.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!) else { return nil }
        return (image, opaqueBox(image) ?? CGRect(x: 0, y: 0, width: image.width, height: image.height))
    }

    /// The smallest box (top-left origin) holding every pixel that is not transparent.
    static func opaqueBox(_ image: CGImage) -> CGRect? {
        let width = image.width, height = image.height
        var alpha = [UInt8](repeating: 0, count: width * height)
        guard let context = CGContext(data: &alpha, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in stride(from: 0, to: height, by: 2) {
            let row = y * width
            for x in stride(from: 0, to: width, by: 2) where alpha[row + x] > 24 {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX + 2, height: maxY - minY + 2)
    }

    /// The head: the opaque part of the top 30 % of the speaker's box (top-left origin).
    /// A clear place keeps it inside the thumbnail.
    static func headBox(_ image: CGImage, box: CGRect) -> CGRect? {
        let band = CGRect(x: box.minX, y: box.minY, width: box.width, height: max(2, box.height * 0.3)).integral
            .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard !band.isEmpty, let part = image.cropping(to: band), let found = opaqueBox(part) else { return nil }
        return found.offsetBy(dx: band.minX, dy: band.minY)
    }

    /// The speaker's outline as boxes, one for each of `count` bands of rows of the box
    /// (bands with nothing in them are left out). A clear place keeps each band clear of
    /// the title by its own width, so wide shoulders below the title do not push the head away.
    static func bands(_ image: CGImage, box: CGRect, count: Int = 24) -> [CGRect] {
        let picture = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let step = box.height / Double(count)
        return (0..<count).compactMap { index in
            let band = CGRect(x: box.minX, y: box.minY + Double(index) * step, width: box.width, height: step).integral
                .intersection(picture)
            guard !band.isEmpty, let part = image.cropping(to: band), let found = opaqueBox(part) else { return nil }
            return found.offsetBy(dx: band.minX, dy: band.minY)
        }
    }
}

// MARK: - Drawing

/// Draws a thumbnail with the graphics engine's thumbnail page, offscreen or in a view.
enum ThumbnailMaker {
    static let size = CGSize(width: PublishInfo.thumbnailSize.width, height: PublishInfo.thumbnailSize.height)

    /// What one thumbnail needs besides its design: the frame and, when found, the speaker.
    struct Sources {
        var frame: CGImage
        var cutout: (image: CGImage, box: CGRect)?
    }

    /// The frame and the cut-out as files in `folder/media`, named by their content.
    struct Media {
        var frame: String
        var cutout: String?
        /// The speaker's box, head and outline bands in the frame's pixels, and the frame's width.
        var box: CGRect?
        var head: CGRect?
        var bands: [CGRect] = []
        var width: Double
    }

    static func writeMedia(_ sources: Sources, folder: URL) throws -> Media {
        let media = folder.appendingPathComponent("media", isDirectory: true)
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        func write(_ image: CGImage, _ name: String) throws -> String {
            guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
                throw FFmpegError(message: "The thumbnail's pictures could not be prepared.")
            }
            let file = "\(ColorCube.sha256(png).prefix(12))-\(name).png"
            let target = media.appendingPathComponent(file)
            if !FileManager.default.fileExists(atPath: target.path) { try png.write(to: target) }
            return "media/" + file
        }
        return Media(frame: try write(sources.frame, "frame"), cutout: try sources.cutout.map { try write($0.image, "speaker") },
                     box: sources.cutout?.box, head: sources.cutout.flatMap { SpeakerCutout.headBox($0.image, box: $0.box) },
                     bands: sources.cutout.map { SpeakerCutout.bands($0.image, box: $0.box) } ?? [],
                     width: Double(sources.frame.width))
    }

    /// The engine's data for a design. The side is decided here: away from the speaker
    /// unless the design says otherwise.
    static func pageData(_ design: ThumbnailDesign, media: Media, accent: String, folder: URL) throws -> Data {
        let scale = 1920 / media.width
        var speaker: JSONValue = .null
        var head: JSONValue = .null
        var bands: JSONValue = .array([])
        var cutout: JSONValue = .null
        func rect(_ box: CGRect) -> JSONValue {
            .object(["x": .number(box.minX * scale), "y": .number(box.minY * scale),
                     "w": .number(box.width * scale), "h": .number(box.height * scale)])
        }
        if design.cutout, let file = media.cutout, let box = media.box {
            cutout = .string(file)
            speaker = rect(box)
            if let box = media.head { head = rect(box) }
            bands = .array(media.bands.map(rect))
        }
        var side = design.side
        if side == .auto {
            let centre = media.box.map { $0.midX / media.width } ?? 0.4
            side = centre < 0.5 ? .right : .left
        }
        var image: JSONValue = .null
        if let url = design.image {
            guard let bytes = try? Data(contentsOf: url) else { throw FFmpegError(message: "The thumbnail's image is missing: \(url.lastPathComponent)") }
            let name = "\(ColorCube.sha256(bytes).prefix(12)).\(url.pathExtension.lowercased())"
            let target = folder.appendingPathComponent("media/" + name)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: target.path) { try bytes.write(to: target) }
            image = .string("media/" + name)
        }
        let root: JSONValue = .object([
            "frame": .string(media.frame), "cutout": cutout, "speaker": speaker, "head": head, "bands": bands, "place": .string(design.place.rawValue),
            "title": .string(design.title), "tag": .string(design.tag), "accent": .string(design.accent ?? accent),
            "image": image, "outline": .bool(design.outline), "outlineWidth": .number(design.outlineWidth),
            "highlight": .bool(design.highlight), "side": .string(side.rawValue),
            "background": .string(design.background.rawValue), "zoom": .number(design.zoom),
            "imageSize": .number(design.imageSize),
        ])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(root)
    }

    /// Writes the thumbnail page: the engine files and an empty thumbnail, filled in by
    /// `YamGraphics.thumbnail(data)`.
    static func writePage(to folder: URL) throws -> URL {
        try GraphicsEngine.writePage(GraphicsTrack(), duration: 1, fps: "30", mode: "thumbnail", to: folder)
    }

    /// The finished 1280×720 picture.
    @MainActor
    static func render(_ design: ThumbnailDesign, sources: Sources, accent: String) async throws -> CGImage {
        let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("YamVideo/Thumbnails/\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let index = try writePage(to: folder)
        let media = try writeMedia(sources, folder: folder)
        let data = String(decoding: try pageData(design, media: media, accent: accent, folder: folder), as: UTF8.self)
        return try await GraphicsSnapshot.capture(page: index, folder: folder, size: size,
                                                  script: "await YamGraphics.thumbnail(\(data));")
    }

    /// The finished 1280×720 picture, what the page measured of it, and `letters`: the same
    /// picture with the title's letters in pure magenta and without their shadow, so the
    /// phone check can tell the letters from what is behind them (`LetterMask`). The check
    /// then samples the finished picture, shadow and all, as the viewer sees it. (Letters
    /// made see-through do not work: at 2× WebKit leaves out their shadow.)
    @MainActor
    static func measure(_ design: ThumbnailDesign, sources: Sources, accent: String) async throws
        -> (image: CGImage, letters: CGImage, layout: ThumbnailLayout) {
        let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("YamVideo/Thumbnails/\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let index = try writePage(to: folder)
        let media = try writeMedia(sources, folder: folder)
        let data = String(decoding: try pageData(design, media: media, accent: accent, folder: folder), as: UTF8.self)
        let shots = try await GraphicsSnapshot.capture(page: index, folder: folder, size: size, steps: [
            "await YamGraphics.thumbnail(\(data));\nreturn JSON.stringify(YamGraphics.thumbnailLayout());",
            "document.querySelectorAll('.yg-thumb-title, .yg-thumb-title em').forEach((node) => { node.style.color = '#FF00FF'; node.style.textShadow = 'none'; });\nreturn null;",
        ])
        guard shots.count == 2, let json = shots[0].result,
              let layout = try? JSONDecoder().decode(ThumbnailLayout.self, from: Data(json.utf8)) else {
            throw FFmpegError(message: "The thumbnail could not be measured.")
        }
        return (shots[0].image, shots[1].image, layout)
    }
}

// MARK: - The frame and the speaker, for a recording

extension AppModel {
    /// The frame at `time` as Preview shows it, without the graphics, and the speaker cut
    /// out of it. Cut-outs are kept by the frame's content, so the same frame is cut once.
    /// With a screen recording, the frame is the speaker's own picture (as in the Speaker
    /// layout) at every moment, so a smile in a part that shows the screen can be used.
    /// The graphics' move aside is left out too, so a frame under the end screen or a
    /// panel shows the speaker at full size.
    func thumbnailSources(_ clip: ProjectClip, at time: Double, cutout: Bool) async throws -> ThumbnailMaker.Sources {
        var speaker = clip
        speaker.screen = nil
        speaker.graphics = nil
        let frame = try await composedFrame(speaker, at: time, settings: settings, graphics: false).image
        guard cutout else { return ThumbnailMaker.Sources(frame: frame) }
        guard let pixels = frame.dataProvider?.data as Data? else { return ThumbnailMaker.Sources(frame: frame) }
        let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("YamVideo/Cutouts", isDirectory: true)
        let file = cache.appendingPathComponent("\(ColorCube.sha256(pixels)).png")
        if let cached = NSImage(contentsOf: file)?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            return ThumbnailMaker.Sources(frame: frame, cutout: (cached, SpeakerCutout.opaqueBox(cached) ?? .zero))
        }
        let cut = try await Task.detached(priority: .userInitiated) { try SpeakerCutout.cut(frame) }.value
        if let cut, let png = NSBitmapImageRep(cgImage: cut.image).representation(using: .png, properties: [:]) {
            try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
            try? png.write(to: file, options: .atomic)
        }
        return ThumbnailMaker.Sources(frame: frame, cutout: cut)
    }

    /// Makes the thumbnail and saves it as a PNG next to the recording.
    func saveThumbnail(_ clip: ProjectClip, design: ThumbnailDesign) async throws -> URL {
        let sources = try await thumbnailSources(clip, at: design.time, cutout: design.cutout)
        let image = try await ThumbnailMaker.render(design, sources: sources, accent: clip.graphics?.style.accent ?? GraphicsStyle().accent)
        guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw FFmpegError(message: "The thumbnail could not be saved.")
        }
        let folder = clip.url.deletingLastPathComponent()
        let stem = clip.url.deletingPathExtension().lastPathComponent + " thumbnail"
        var target = folder.appendingPathComponent(stem + ".png")
        var counter = 2
        while FileManager.default.fileExists(atPath: target.path) {
            target = folder.appendingPathComponent("\(stem) \(counter).png"); counter += 1
        }
        try png.write(to: target, options: .atomic)
        return target
    }
}
