import Foundation

/// The central document (PLAN.md §3.1). Every render is a pure function of
/// this value. The Edit tab is a view over it; a later CLI renders it headless.
public struct EditDoc: Codable, Sendable, Equatable {
    public var version = 3
    public var output = OutputSettings()
    public var sources: [Source] = []
    public var timeline: [Segment] = []
    public var screen = ScreenSettings()
    public var blurs: [BlurRegion] = []
    public var facecam: FacecamSettings?

    public init() {}
}

public struct OutputSettings: Codable, Sendable, Equatable {
    public enum Format: String, Codable, Sendable { case mp4, gif }
    public var format: Format = .mp4
    public var width = 1920
    public var height = 1080
    public var fps = 30
    public var preset: ExportPreset = .webSafeH264
    public var gif = GifSettings()

    public init() {}
}

public struct GifSettings: Codable, Sendable, Equatable {
    public enum Dither: String, Codable, Sendable, CaseIterable {
        case bayer, sierra2_4a, none
        public var label: String {
            switch self {
            case .bayer: return "Bayer (smaller)"
            case .sierra2_4a: return "Sierra (smoother)"
            case .none: return "None"
            }
        }
    }
    public var fps = 15
    public var width = 800
    public var loop = true
    public var dither: Dither = .bayer

    public init() {}
}

public struct Source: Codable, Sendable, Equatable, Identifiable {
    public enum Role: String, Codable, Sendable { case screen, facecam }
    public var id: String
    public var path: String
    public var role: Role
    /// Facecam shift relative to the screen source, ms. Zero by construction
    /// for takes recorded in the app (§2.3); nonzero only for external pairs.
    public var offsetMs: Int = 0

    public init(id: String, path: String, role: Role, offsetMs: Int = 0) {
        self.id = id
        self.path = path
        self.role = role
        self.offsetMs = offsetMs
    }
}

/// One stretch of a source on the timeline. Segments play end to end in
/// array order — there is no gap concept (§3.2).
public struct Segment: Codable, Sendable, Equatable, Identifiable {
    public var id = UUID()
    public var sourceId: String
    public var inMs: Int
    public var outMs: Int

    public var durationMs: Int { max(0, outMs - inMs) }

    public init(sourceId: String, inMs: Int, outMs: Int) {
        self.sourceId = sourceId
        self.inMs = inMs
        self.outMs = outMs
    }
}

public struct ScreenSettings: Codable, Sendable, Equatable {
    public var crop = CropSettings()
    public var muteAudio = false

    public init() {}
}

public struct CropSettings: Codable, Sendable, Equatable {
    public enum Mode: String, Codable, Sendable { case none, aspect, rect }
    public var mode: Mode = .none
    /// e.g. "16:9", "1:1" — used when mode == .aspect
    public var aspect: String?
    /// Normalized 0–1 rect — used when mode == .rect
    public var rect: NormalizedRect?

    public init() {}
}

/// Privacy blur (§2.7): glued to *source* time so it survives trims/reorders.
public struct BlurRegion: Codable, Sendable, Equatable, Identifiable {
    public var id = UUID()
    public var sourceId: String
    public var rect: NormalizedRect
    public var fromMs: Int = 0
    /// nil = until the end of the source
    public var toMs: Int?
    public var radius: Double = 24

    public init(sourceId: String, rect: NormalizedRect, fromMs: Int = 0,
                toMs: Int? = nil, radius: Double = 24) {
        self.sourceId = sourceId
        self.rect = rect
        self.fromMs = fromMs
        self.toMs = toMs
        self.radius = radius
    }
}

public struct NormalizedRect: Codable, Sendable, Equatable {
    public var x: Double
    public var y: Double
    public var w: Double
    public var h: Double

    public init(x: Double, y: Double, w: Double, h: Double) {
        self.x = x
        self.y = y
        self.w = w
        self.h = h
    }
}

/// Mirrors the app's CameraPlacement (kept as strings so YVCore stays UI-free
/// and the JSON matches what the capture side already persists).
public struct FacecamSettings: Codable, Sendable, Equatable {
    public var enabled = true
    public var fillMode = "Fill"
    public var corner = "Bottom right"
    public var sizeFraction = 0.28
    public var offset = 0.0
    public var shape = "Rounded"
    public var frame: FramePack?
    public var audioEnabled = true
    public var gainDb = 0.0

    public init() {}
}

public struct FramePack: Codable, Sendable, Equatable {
    public var pack: String
    public var params: [String: Double] = [:]

    public init(pack: String, params: [String: Double] = [:]) {
        self.pack = pack
        self.params = params
    }
}
