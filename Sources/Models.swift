import Foundation

// MARK: - Media info (from ffprobe)

struct MediaInfo: Equatable {
    /// Dimensions as displayed (rotation metadata already applied), in pixels.
    var width: Int
    var height: Int
    var duration: Double
    var videoCodec: String
    var audioCodec: String?
    var fps: Double
    /// Exact frame rate as ffprobe reports it, e.g. "30000/1001". Rounding this to 30
    /// makes zoompan resample and drifts audio out of sync on long clips.
    var fpsExpression: String
    var rotation: Int
    /// ffprobe's `color_transfer`, verbatim. Nil when the file does not say.
    var colorTransfer: String?

    var hasAudio: Bool { audioCodec != nil }

    /// True for PQ (HDR10) and HLG sources. Both need tone mapping on the way to SDR:
    /// converting one to 8-bit yuv420p without it produces a file that is still tagged
    /// HDR, and every player that honours the tag stretches it back out and shows it
    /// blown out. QuickTime on the recording Mac can hide this; nothing else does.
    var isHDR: Bool {
        guard let colorTransfer else { return false }
        return colorTransfer == "smpte2084" || colorTransfer == "arib-std-b67"
    }

    /// What to call the source's HDR flavour in the UI.
    var hdrLabel: String? {
        guard let colorTransfer else { return nil }
        switch colorTransfer {
        case "smpte2084": return "HDR10 (PQ)"
        case "arib-std-b67": return "HLG"
        default: return nil
        }
    }

    /// Whether the source audio can be copied into an MP4 and still play everywhere.
    /// ffmpeg will happily copy PCM in as `ipcm`, but QuickTime and Safari cannot decode it.
    var audioIsMP4Compatible: Bool {
        guard let audioCodec else { return true }
        return ["aac", "mp3", "mp4a", "alac", "ac3", "eac3"].contains(audioCodec)
    }

    var aspect: CGFloat { CGFloat(width) / CGFloat(max(height, 1)) }
    var fullFrame: CGRect { CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)) }
}

// MARK: - Blur regions

/// A rectangle to obscure, in source pixels against the *displayed* (rotation-applied)
/// frame — the same coordinate space as the crop rectangle.
struct BlurRegion: Identifiable, Equatable {
    let id: UUID
    var rect: CGRect

    init(id: UUID = UUID(), rect: CGRect) {
        self.id = id
        self.rect = rect
    }
}

enum BlurStyle: String, CaseIterable, Identifiable {
    case blur, pixelate, black

    var id: String { rawValue }

    var label: String {
        switch self {
        case .blur: return "Blur"
        case .pixelate: return "Pixelate"
        case .black: return "Black box"
        }
    }

    var detail: String {
        switch self {
        case .blur: return "Soft gaussian blur — looks natural."
        case .pixelate: return "Chunky mosaic — obviously redacted."
        case .black: return "Solid fill — nothing recoverable."
        }
    }
}

enum EditorMode: String, CaseIterable, Identifiable {
    case crop, blur, zoom
    var id: String { rawValue }
    var label: String {
        switch self {
        case .crop: return "Crop"
        case .blur: return "Blur"
        case .zoom: return "Zoom"
        }
    }
}

// MARK: - Zoom shots

/// A push-in on one spot: ease in, hold still, ease back out.
struct ZoomShot: Identifiable, Equatable {
    let id: UUID
    /// When the ease-in begins, in seconds.
    var start: Double
    /// How long the view holds at full zoom, in seconds.
    var hold: Double
    /// Magnification at the peak of the shot.
    var level: Double
    /// Where to zoom, in full-frame source pixels (same space as crop and blur).
    var target: CGPoint

    /// Fixed on purpose: a consistent ease is most of what makes these look deliberate.
    static let ease: Double = 0.5
    static let levels: [Double] = [1.5, 2, 3]

    init(id: UUID = UUID(), start: Double, hold: Double = 2, level: Double = 2, target: CGPoint) {
        self.id = id
        self.start = start
        self.hold = hold
        self.level = level
        self.target = target
    }

    /// Total time on screen, including both eases.
    var duration: Double { Self.ease * 2 + hold }
    var end: Double { start + duration }
    var levelLabel: String { level == level.rounded() ? "\(Int(level))×" : String(format: "%.1f×", level) }

    func overlaps(_ other: ZoomShot) -> Bool {
        start < other.end && other.start < end
    }
}

// MARK: - Queue item

struct VideoItem: Identifiable {
    enum Status: Equatable {
        case probing
        case ready
        case converting(Double)
        case done(URL)
        case failed(String)

        var isBusy: Bool {
            switch self {
            case .probing, .converting: return true
            default: return false
            }
        }
    }

    let id = UUID()
    let url: URL
    var info: MediaInfo?
    /// Crop rectangle in source pixels, origin top-left. Nil until probed.
    var crop: CGRect?
    /// Locked crop aspect (width / height), nil = free.
    var aspectLock: CGFloat?
    var aspectLabel: String = "Free"
    /// Areas to obscure, applied before the crop.
    var blurRegions: [BlurRegion] = []
    /// Push-ins, applied after the crop. Kept sorted and non-overlapping.
    var zoomShots: [ZoomShot] = []
    var status: Status = .probing
    /// Preview scrub position, 0...1.
    var previewFraction: Double = 0.15

    var name: String { url.lastPathComponent }

    var cropIsFullFrame: Bool {
        guard let info, let crop else { return true }
        return crop.integral == info.fullFrame
    }
}

// MARK: - Export settings

enum VideoEncoder: String, CaseIterable, Identifiable {
    case x264
    case h264VT
    case hevcVT

    var id: String { rawValue }

    var label: String {
        switch self {
        case .x264: return "H.264 · x264 (best quality)"
        case .h264VT: return "H.264 · VideoToolbox (fast)"
        case .hevcVT: return "HEVC · VideoToolbox (smallest)"
        }
    }

    var isHardware: Bool { self != .x264 }
}

enum AudioMode: String, CaseIterable, Identifiable {
    case aac, normalised, copy, none
    var id: String { rawValue }
    var label: String {
        switch self {
        case .aac: return "Re-encode to AAC 192k"
        case .normalised: return "Normalise loudness (AAC 192k)"
        case .copy: return "Copy original stream"
        case .none: return "Remove audio"
        }
    }
}

/// The loudness every major platform normalises toward: -14 LUFS integrated, -1 dBTP
/// true peak, 11 LU range. Hitting it means YouTube, Instagram, TikTok and LinkedIn
/// leave the audio alone instead of turning it down on the way in.
enum Loudness {
    static let filterTargets = "I=-14:TP=-1:LRA=11"
    static let summary = "-14 LUFS, -1 dBTP"
}

/// What `loudnorm`'s analysis pass measured about a clip.
///
/// The values are kept as the strings ffmpeg printed rather than parsed into Doubles,
/// for the same reason the frame rate is: they go straight back to ffmpeg, and a
/// round trip through a Double only invents rounding.
struct LoudnessMeasurement: Equatable {
    var inputI: String
    var inputTP: String
    var inputLRA: String
    var inputThresh: String
    var targetOffset: String

    /// Appended to the second pass's `loudnorm`. Without these the filter still runs,
    /// but as a dynamic-range compressor rather than the straight gain match that two
    /// passes buy; `linear=true` is what asks for the gain match.
    var filterArguments: String {
        "measured_I=\(inputI):measured_TP=\(inputTP):measured_LRA=\(inputLRA)"
            + ":measured_thresh=\(inputThresh):offset=\(targetOffset):linear=true"
    }
}

enum SizeLimit: Int, CaseIterable, Identifiable {
    case original = 0
    case uhd = 3840
    case qhd = 2560
    case fhd = 1920
    case hd = 1280
    case sd = 854
    case vga = 640
    case small = 480

    var id: Int { rawValue }
    var label: String {
        switch self {
        case .original: return "Original size"
        case .uhd: return "Max 3840 px (4K)"
        case .qhd: return "Max 2560 px"
        case .fhd: return "Max 1920 px (1080p)"
        case .hd: return "Max 1280 px (720p)"
        case .sd: return "Max 854 px (480p)"
        case .vga: return "Max 640 px"
        case .small: return "Max 480 px"
        }
    }
}

// MARK: - Output format

enum OutputFormat: String, CaseIterable, Identifiable {
    case mp4, gif, webp

    var id: String { rawValue }

    var label: String {
        switch self {
        case .mp4: return "MP4 video"
        case .gif: return "Animated GIF"
        case .webp: return "Animated WebP"
        }
    }

    var detail: String {
        switch self {
        case .mp4: return "H.264 or HEVC with sound. Plays everywhere."
        case .gif: return "Plays in anything — email, wikis, ancient chat apps — but the files are big."
        case .webp: return "The same silent loop as a GIF at a fraction of the size. Every current browser plays it."
        }
    }

    var fileExtension: String {
        switch self {
        case .mp4: return "mp4"
        case .gif: return "gif"
        case .webp: return "webp"
        }
    }

    /// Silent looping image formats: no audio track, and no encoder or preset to pick.
    var isAnimation: Bool { self != .mp4 }

    /// The muxer's `-loop` value. The two formats disagree about what "play once" is:
    /// GIF spells it -1, WebP spells it 1. Nil where looping means nothing.
    func loopValue(forever: Bool) -> String? {
        switch self {
        case .mp4: return nil
        case .gif: return forever ? "0" : "-1"
        case .webp: return forever ? "0" : "1"
        }
    }
}

/// Frame rate for GIF/WebP. Dropping frames is the single biggest saving available —
/// a 30 fps GIF is twice the file of a 15 fps one and rarely looks better.
enum AnimationFrameRate: Int, CaseIterable, Identifiable {
    case source = 0
    case fps24 = 24
    case fps20 = 20
    case fps15 = 15
    case fps12 = 12
    case fps10 = 10

    var id: Int { rawValue }
    var label: String { self == .source ? "Source frame rate" : "\(rawValue) fps" }
    /// Nil means "leave the frame rate alone".
    var value: Double? { self == .source ? nil : Double(rawValue) }
}

/// Palette size for GIF. Fewer colours is a smaller file and, on screen recordings
/// (flat UI colours), usually indistinguishable.
enum GIFColors: Int, CaseIterable, Identifiable {
    case full = 256
    case half = 128
    case quarter = 64
    case minimal = 32

    var id: Int { rawValue }
    var label: String {
        switch self {
        case .full: return "256 colours (best)"
        case .half: return "128 colours"
        case .quarter: return "64 colours"
        case .minimal: return "32 colours (smallest)"
        }
    }
}

enum GIFDither: String, CaseIterable, Identifiable {
    case bayer, diffusion, none

    var id: String { rawValue }

    var label: String {
        switch self {
        case .bayer: return "Ordered (smallest file)"
        case .diffusion: return "Diffusion (smoothest)"
        case .none: return "None (flat colour)"
        }
    }

    var detail: String {
        switch self {
        case .bayer: return "A fixed pattern, so it compresses well between frames."
        case .diffusion: return "Best gradients, but the noise it adds inflates the file."
        case .none: return "Hard edges between colours. Ideal for flat UI and text."
        }
    }

    /// The value handed to `paletteuse=dither=`.
    var filterValue: String {
        switch self {
        case .bayer: return "bayer:bayer_scale=5"
        case .diffusion: return "sierra2_4a"
        case .none: return "none"
        }
    }
}

struct ExportSettings: Equatable {
    var format: OutputFormat = .mp4
    var encoder: VideoEncoder = .x264
    /// 0 = smallest file, 100 = best quality.
    var quality: Double = 70
    var preset: String = "medium"
    var sizeLimit: SizeLimit = .original
    var audio: AudioMode = .aac
    /// Tone-map HLG/PQ sources down to Rec.709. Only consulted when the clip is HDR.
    var toneMapHDR: Bool = true
    var blurStyle: BlurStyle = .blur
    /// How hard to obscure: gaussian sigma, or the mosaic block size.
    var blurStrength: Double = 24
    /// GIF and WebP only, from here down.
    var frameRate: AnimationFrameRate = .fps15
    var loopForever: Bool = true
    var gifColors: GIFColors = .full
    var gifDither: GIFDither = .bayer
    /// Pixel-exact WebP. Much larger, but the right choice for text and flat UI.
    var webpLossless: Bool = false
    /// Nil means "next to the source file".
    var outputFolder: URL?
    var suffix: String = "-converted"

    static let presets = ["ultrafast", "veryfast", "faster", "fast", "medium", "slow", "slower"]

    /// x264 / x265 constant rate factor.
    var crf: Int { Int((30 - (quality / 100) * 16).rounded()) }
    /// VideoToolbox constant-quality value (1...100).
    var vtQuality: Int { max(1, min(100, Int((20 + quality * 0.62).rounded()))) }
    /// libwebp quality (0...100) — the same slider the video encoders use.
    var webpQuality: Int { max(0, min(100, Int(quality.rounded()))) }

    var qualityDescription: String {
        switch format {
        case .mp4: return encoder.isHardware ? "q \(vtQuality)" : "CRF \(crf)"
        case .gif: return "\(gifColors.rawValue) colours"
        case .webp: return webpLossless ? "lossless" : "q \(webpQuality)"
        }
    }
}

// MARK: - Crop aspect presets

struct AspectPreset: Identifiable, Hashable {
    let label: String
    /// Nil = free-form.
    let ratio: CGFloat?
    var id: String { label }

    static let all: [AspectPreset] = [
        .init(label: "Free", ratio: nil),
        .init(label: "16:9", ratio: 16.0 / 9.0),
        .init(label: "9:16", ratio: 9.0 / 16.0),
        .init(label: "1:1", ratio: 1),
        .init(label: "4:5", ratio: 4.0 / 5.0),
        .init(label: "4:3", ratio: 4.0 / 3.0),
        .init(label: "2.39:1", ratio: 2.39),
    ]
}

// MARK: - Geometry helpers

extension CGRect {
    /// Largest rect of `ratio` centred inside `bounds`.
    static func centered(aspect ratio: CGFloat, in bounds: CGRect) -> CGRect {
        var w = bounds.width
        var h = w / ratio
        if h > bounds.height {
            h = bounds.height
            w = h * ratio
        }
        return CGRect(x: bounds.midX - w / 2, y: bounds.midY - h / 2, width: w, height: h)
    }

    /// Even-numbered pixel rect clamped inside `bounds` — what ffmpeg's crop filter needs.
    func evenClamped(in bounds: CGRect, minSide: CGFloat = 16) -> CGRect {
        func even(_ v: CGFloat) -> CGFloat { (v / 2).rounded(.down) * 2 }
        var w = max(minSide, even(width))
        var h = max(minSide, even(height))
        w = min(w, even(bounds.width))
        h = min(h, even(bounds.height))
        let x = min(max(0, even(minX)), even(bounds.width - w))
        let y = min(max(0, even(minY)), even(bounds.height - h))
        return CGRect(x: x, y: y, width: w, height: h)
    }
}

func formatDuration(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "--:--" }
    let total = Int(seconds.rounded())
    let h = total / 3600, m = (total % 3600) / 60, s = total % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
}
