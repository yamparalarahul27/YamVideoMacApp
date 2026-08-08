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

    var hasAudio: Bool { audioCodec != nil }

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
    case aac, copy, none
    var id: String { rawValue }
    var label: String {
        switch self {
        case .aac: return "Re-encode to AAC 192k"
        case .copy: return "Copy original stream"
        case .none: return "Remove audio"
        }
    }
}

enum SizeLimit: Int, CaseIterable, Identifiable {
    case original = 0
    case uhd = 3840
    case qhd = 2560
    case fhd = 1920
    case hd = 1280
    case sd = 854

    var id: Int { rawValue }
    var label: String {
        switch self {
        case .original: return "Original size"
        case .uhd: return "Max 3840 px (4K)"
        case .qhd: return "Max 2560 px"
        case .fhd: return "Max 1920 px (1080p)"
        case .hd: return "Max 1280 px (720p)"
        case .sd: return "Max 854 px (480p)"
        }
    }
}

struct ExportSettings: Equatable {
    var encoder: VideoEncoder = .x264
    /// 0 = smallest file, 100 = best quality.
    var quality: Double = 70
    var preset: String = "medium"
    var sizeLimit: SizeLimit = .original
    var audio: AudioMode = .aac
    var blurStyle: BlurStyle = .blur
    /// How hard to obscure: gaussian sigma, or the mosaic block size.
    var blurStrength: Double = 24
    /// Nil means "next to the source file".
    var outputFolder: URL?
    var suffix: String = "-converted"

    static let presets = ["ultrafast", "veryfast", "faster", "fast", "medium", "slow", "slower"]

    /// x264 / x265 constant rate factor.
    var crf: Int { Int((30 - (quality / 100) * 16).rounded()) }
    /// VideoToolbox constant-quality value (1...100).
    var vtQuality: Int { max(1, min(100, Int((20 + quality * 0.62).rounded()))) }

    var qualityDescription: String {
        encoder.isHardware ? "q \(vtQuality)" : "CRF \(crf)"
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
