import AppKit
import CoreGraphics

// The graphics gallery (docs/plans/graphics-gallery.md, part 1): each kind a person can
// add, as a tile with a picture the engine draws in the recording's style, and a look at
// one on the Preview before it is added.

/// One kind in the gallery, with sample words to show it.
struct GallerySample: Identifiable, Equatable {
    enum Group: String, CaseIterable, Identifiable {
        case cards = "Cards", fullScreen = "Full screen", panels = "Panels", end = "End"
        var id: String { rawValue }
    }

    let asset: MediaAsset
    let kind: GraphicKind
    let title: String
    /// One short line under the title; the longer help is the tooltip.
    let detail: String
    let help: String
    let group: Group
    let props: [String: JSONValue]
    /// How long the sample runs, and the moment of it the picture shows, in seconds after
    /// its start: a beat where everything has come in.
    let length: Double
    let beat: Double
    var id: String { asset.id }

    static let all: [GallerySample] = [
        GallerySample(asset: .namePlate, kind: .namePlate, title: "Name plate", detail: "Your name, beside you",
                      help: "Your name and what you do, beside you", group: .cards,
                      props: ["title": .string("Yamparala Rahul"), "detail": .string("UX Design Engineer")], length: 4, beat: 1.6),
        GallerySample(asset: .titleCard, kind: .titleCard, title: "Title card", detail: "A title and one line",
                      help: "A short title with one line under it, in the column", group: .cards,
                      props: ["kicker": .string("Feedback 1"), "title": .string("Use the space"), "detail": .string("A wider strategy panel"),
                              "badgesAt": .number(1)], length: 4, beat: 2.2),
        GallerySample(asset: .featureList, kind: .featureList, title: "Feature list", detail: "Two to four rows",
                      help: "Two to four rows, each with an icon, a title and a line", group: .cards,
                      props: ["kicker": .string("What works"), "items": .array([
                          .object(["icon": .string("app"), "title": .string("Clear empty state"), "detail": .string("Tells you what to do"), "at": .number(0.2)]),
                          .object(["icon": .string("check"), "title": .string("Shows its steps"), "detail": .string("While the AI works"), "at": .number(0.7)]),
                      ])], length: 5, beat: 2.6),
        GallerySample(asset: .kineticText, kind: .kineticText, title: "Kinetic text", detail: "Big words, as said",
                      help: "Big words over the picture, each when it is said", group: .fullScreen,
                      props: ["background": .string("overlay"), "text": .string("Show the user *what's under the hood*")], length: 3.6, beat: 2.4),
        GallerySample(asset: .sectionCard, kind: .sectionCard, title: "Section card", detail: "A part's title, seek bar",
                      help: "A part's title over a seek bar that shows how far into the video it starts", group: .fullScreen,
                      props: ["background": .string("overlay"), "title": .string("Backtest results"),
                              "marks": .array([.number(0.12), .number(0.22), .number(0.57)]), "progress": .number(0.57)], length: 2.4, beat: 1.5),
        GallerySample(asset: .checklist, kind: .checklist, title: "Checklist", detail: "Ticks in the side panel",
                      help: "A short list that ticks off, in the side panel", group: .panels,
                      props: ["title": .string("A good start"), "kicker": .string(""), "footer": .string(""), "items": .array([
                          .object(["at": .number(0.5), "text": .string("Clear empty state")]),
                          .object(["at": .number(1.0), "text": .string("Shows its steps")]),
                          .object(["at": .number(1.5), "text": .string("Info icons")]),
                      ])], length: 5, beat: 3.6),
        GallerySample(asset: .endScreen, kind: .endScreen, title: "End screen", detail: "The last 5–20 s",
                      help: "The last 5 to 20 seconds, with boxes for YouTube's end screen", group: .end,
                      props: EndScreen.defaultProps, length: 10, beat: 3),
    ]

    /// The sample on its own as a track in `style`, drawn as `look` shows it, without the
    /// video's move aside (the gallery draws over a still picture).
    func track(style: GraphicsStyle, look: GalleryLook) -> GraphicsTrack {
        var shown = style
        shown.moveVideo = false
        var track = GraphicsTrack(style: shown)
        track.items = [Graphic(id: GallerySample.draftID, kind: kind, start: 0, end: length, props: props(for: look), look: look.graphicLook(for: kind))]
        return track
    }

    /// The sample's words as `look` shows them: in Paper the title card has a label too, so
    /// its tile shows the sticker.
    func props(for look: GalleryLook) -> [String: JSONValue] {
        guard look == .paper, kind == .titleCard else { return props }
        return props.merging(["label": .string("best feature")]) { $1 }
    }

    /// What the picture depends on: the engine, the sample, the style and the look.
    func pictureKey(style: GraphicsStyle, look: GalleryLook) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = (try? encoder.encode(track(style: style, look: look))) ?? Data()
        return ColorCube.sha256(Data((GraphicsRender.engineStamp + GalleryPictures.drawing + id + look.rawValue).utf8) + data)
    }

    /// A look at the sample on the Preview, not in the project: placed so the playhead
    /// sees its beat, as the gallery's look draws it.
    func draft(at time: Double, look: GalleryLook) -> Graphic {
        let start = time - beat
        return Graphic(id: GallerySample.draftID, kind: kind, start: start, end: start + length, props: props(for: look), look: look.graphicLook(for: kind))
    }

    /// The draft's id, the same every time, so the Preview treats each new look as one graphic.
    static let draftID = UUID(uuidString: "0A11E2E7-0000-4000-8000-0000000000D1")!
}

/// The looks the gallery shows. Ink draws the panel kinds by hand and Paper puts the card
/// kinds on taped paper; the other kinds stay glass.
enum GalleryLook: String, CaseIterable, Identifiable {
    case glass, ink, paper

    var id: String { rawValue }
    var label: String {
        switch self {
        case .glass: return "Glass"
        case .ink: return "Ink"
        case .paper: return "Paper"
        }
    }

    /// The look the gallery opens with: the recording's own (ink + glass draws the panel
    /// kinds in ink, as ink does).
    init(style: GraphicsStyle) {
        switch style.look {
        case .glass: self = .glass
        case .ink, .mix: self = .ink
        case .paper: self = .paper
        }
    }

    /// The look a graphic of `kind` gets in the gallery's pictures and drafts: given in full
    /// for each kind that has more than one look, so the recording's style never changes it;
    /// nil for a kind that has glass only.
    func graphicLook(for kind: GraphicKind) -> GraphicsLook? {
        guard kind.hasInk || kind.hasPaper else { return nil }
        switch self {
        case .glass: return .glass
        case .ink: return kind.hasInk ? .ink : .glass
        case .paper: return kind.hasPaper ? .paper : .glass
        }
    }

    /// The name of the look a graphic of `kind` shows in, for the Preview's bar: a feature
    /// list in the Paper gallery is still glass.
    func name(for kind: GraphicKind) -> String {
        switch graphicLook(for: kind) {
        case .ink?: return GalleryLook.ink.label
        case .paper?: return GalleryLook.paper.label
        default: return GalleryLook.glass.label
        }
    }

    /// The graphic's own look when it is added, so it comes in as the gallery showed it;
    /// nil when the style already draws it so.
    func addedLook(for kind: GraphicKind, style: GraphicsStyle) -> GraphicsLook? {
        guard let shown = graphicLook(for: kind) else { return nil }
        return GraphicsTrack(style: style).look(of: Graphic(kind: kind, start: 0, end: 1)) == shown ? nil : shown
    }
}

/// The gallery's pictures: drawn by the engine offscreen, one at a time, and kept on disk by
/// what they depend on, so a new accent, size, look or engine draws them again.
@MainActor
final class GalleryPictures: ObservableObject {
    static let shared = GalleryPictures()
    @Published private(set) var pictures: [String: NSImage] = [:]
    private var waiting: Set<String> = []
    private var queue: Task<Void, Never>?

    /// The frame the engine draws in. A tile shows part of it, so it is larger than a tile.
    static let size = CGSize(width: 1280, height: 720)
    /// How the pictures are drawn, in their key: a new way draws them again.
    nonisolated static let drawing = "framed-1280"
    static var folder: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("YamVideo/Gallery", isDirectory: true)
    }

    /// Draws the picture for `sample` unless it is shown or on its way already.
    func request(_ sample: GallerySample, style: GraphicsStyle, look: GalleryLook) {
        let key = sample.pictureKey(style: style, look: look)
        guard pictures[key] == nil, !waiting.contains(key) else { return }
        waiting.insert(key)
        let previous = queue
        queue = Task { @MainActor in
            await previous?.value
            defer { waiting.remove(key) }
            let file = Self.folder.appendingPathComponent(key + ".png")
            if let kept = NSImage(contentsOf: file) { pictures[key] = kept; return }
            guard let image = try? await Self.draw(sample, style: style, look: look).image else { return }
            let picture = NSImage(cgImage: image, size: .zero)
            pictures[key] = picture
            if let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
                try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
                try? png.write(to: file, options: .atomic)
            }
        }
    }

    func picture(_ sample: GallerySample, style: GraphicsStyle, look: GalleryLook) -> NSImage? {
        pictures[sample.pictureKey(style: style, look: look)]
    }

    /// The sample at its beat over a neutral backdrop, cut to the part of the frame around it,
    /// so a card reads at a tile's size. `framing` is that part, in the backdrop's pixels.
    static func draw(_ sample: GallerySample, style: GraphicsStyle, look: GalleryLook) async throws -> (image: CGImage, framing: CGRect) {
        let drawn = try await GraphicsSnapshot.draw(sample.track(style: style, look: look), duration: sample.length, fps: "30",
                                                    time: sample.beat, over: backdrop)
        let rect = framing(drawn.boxes[GallerySample.draftID] ?? CGRect(origin: .zero, size: size), in: size)
        return (drawn.image.cropping(to: rect) ?? drawn.image, rect)
    }

    /// The part of a frame of `size` a tile shows for a graphic in `box` (top-left origin):
    /// the box with room around it, at 16:9, at least 42% of the frame wide, inside the frame.
    static func framing(_ box: CGRect, in size: CGSize) -> CGRect {
        let width = min(size.width, max(box.width * 1.5, box.height * 1.5 * 16 / 9, size.width * 0.42))
        let height = width * 9 / 16
        let x = min(max(0, box.midX - width / 2), size.width - width)
        let y = min(max(0, box.midY - height / 2), size.height - height)
        return CGRect(x: x, y: y, width: width, height: height).integral.intersection(CGRect(origin: .zero, size: size))
    }

    /// A dark, soft backdrop with no footage: the gallery shows the graphic, not a video.
    static let backdrop: CGImage = {
        let w = Int(size.width), h = Int(size.height)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(srgbRed: 0.11, green: 0.12, blue: 0.15, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: w, height: h))
        // Soft light blobs, as a room out of focus: (centre, radius, colour), y from the bottom.
        let blobs: [(CGPoint, CGFloat, (CGFloat, CGFloat, CGFloat))] = [
            (CGPoint(x: 0.78, y: 0.65), 0.42, (0.30, 0.25, 0.38)),
            (CGPoint(x: 0.16, y: 0.22), 0.36, (0.15, 0.24, 0.27)),
            (CGPoint(x: 0.51, y: 0.82), 0.30, (0.24, 0.25, 0.29)),
        ]
        for (centre, radius, colour) in blobs {
            let c = CGPoint(x: centre.x * CGFloat(w), y: centre.y * CGFloat(h))
            let colours = [CGColor(srgbRed: colour.0, green: colour.1, blue: colour.2, alpha: 0.9),
                           CGColor(srgbRed: colour.0, green: colour.1, blue: colour.2, alpha: 0)] as CFArray
            if let gradient = CGGradient(colorsSpace: space, colors: colours, locations: [0, 1]) {
                context.drawRadialGradient(gradient, startCenter: c, startRadius: 0, endCenter: c,
                                           endRadius: radius * CGFloat(w), options: [])
            }
        }
        return context.makeImage()!
    }()
}

/// The gallery sample the Preview shows, its recording, and the playhead's time when it was
/// chosen. The time stays, so moving the playhead does not hand the Preview new graphics at
/// every frame.
struct GalleryDraft: Equatable {
    var sample: String
    var clip: UUID?
    var time: Double
}

extension AppModel {
    /// The recording's graphics style, or the default when it has no graphics yet.
    var galleryStyle: GraphicsStyle { selectedItem?.graphics?.style ?? GraphicsStyle() }

    /// Shows `sample` on the Preview at the playhead, or stops showing it when it already is.
    func toggleGalleryDraft(_ sample: GallerySample) {
        if galleryDraft?.sample == sample.id { galleryDraft = nil; return }
        playback.pause()
        galleryDraft = GalleryDraft(sample: sample.id, clip: selectedItem?.id, time: previewTime)
    }

    var galleryDraftSample: GallerySample? {
        galleryDraft.flatMap { draft in draft.clip == selectedItem?.id ? GallerySample.all.first { $0.id == draft.sample } : nil }
    }

    /// Opens the gallery in the recording's look, once for each recording, so a look the
    /// person picks stays while they work on it.
    func openGallery() {
        guard galleryLookClip != selectedItem?.id else { return }
        galleryLookClip = selectedItem?.id
        galleryLook = GalleryLook(style: galleryStyle)
    }

    /// The graphic the Preview shows for the gallery, if one is chosen for this recording.
    var galleryDraftGraphic: Graphic? {
        guard let draft = galleryDraft, draft.clip == selectedItem?.id, let sample = galleryDraftSample else { return nil }
        return sample.draft(at: draft.time, look: galleryLook)
    }

    /// Hands the draft to the player, so the picture moves aside for a panel as it will in the
    /// project. An end screen is left out: its move lasts to the end of the video.
    func showGalleryDraft() {
        let draft = galleryDraftGraphic.flatMap { graphic in
            selectedItem.flatMap { graphic.kind == .endScreen ? nil : (clip: $0.id, graphic: graphic) }
        }
        guard (draft == nil) != (playback.galleryDraft == nil) || draft?.graphic != playback.galleryDraft?.graphic else { return }
        playback.galleryDraft = draft
        if showPlayback, let item = selectedItem, !isMovieMode {
            playback.prepare(item, settings: settings, at: previewTime, play: false)
        }
    }

    /// Adds `sample`'s kind at the playhead, in the look the gallery shows.
    func addFromGallery(_ sample: GallerySample) {
        let look = galleryLook.addedLook(for: sample.kind, style: galleryStyle)
        let before = Set(selectedItem?.graphics?.items.map(\.id) ?? [])
        add(sample.asset)
        galleryDraft = nil
        guard let look, let item = selectedItem,
              let added = item.graphics?.items.first(where: { !before.contains($0.id) }) else { return }
        var changed = added
        changed.look = look
        _ = perform([.updateGraphic(clip: item.id, graphic: changed)], label: "\(sample.title) in \(galleryLook.name(for: sample.kind))")
    }
}
