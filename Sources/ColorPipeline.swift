import CoreImage
import Foundation

// MARK: - Table store

/// Where imported conversion tables live, named by content hash.
///
/// A project refers to a table by hash, so the same file imported twice is one table
/// and a changed file is never mistaken for the one a project was graded with. Nothing
/// here is cleaned up automatically: undo, recovery and other projects may still need it.
enum LUTStore {
    /// SHA-256 of DJI's "DJI OSMO Pocket 3 D-Log M to Rec.709 V1.cube", as downloaded from
    /// `downloadPage` on 2026-10-14. A file matching it is DJI's own conversion.
    static let officialPocket3 = "b18162854ab47702068410c33afa98a8cb6eef159fc5a04ce0e65fad0fd8947e"
    static let downloadPage = URL(string: "https://www.dji.com/downloads/softwares/osmo-pocket-3-dlog-to-rec709")!

    /// The folder beside a saved project that carries its tables, so the project still
    /// opens corrected on another Mac. Content-addressed, so projects can share it.
    static let projectFolderName = "YamVideo Assets"

    static var directory: URL {
        if let override = ProcessInfo.processInfo.environment["YAMVIDEO_LUT_STORE"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("YamVideo/LUTs", isDirectory: true)
    }

    static func url(for sha256: String) -> URL { directory.appendingPathComponent("\(sha256).cube") }

    static func projectURL(for sha256: String, beside project: URL) -> URL {
        project.deletingLastPathComponent()
            .appendingPathComponent(projectFolderName, isDirectory: true)
            .appendingPathComponent("LUTs", isDirectory: true)
            .appendingPathComponent("\(sha256).cube")
    }

    static func isOfficial(_ ref: LUTAssetRef) -> Bool { ref.sha256 == officialPocket3 }

    /// Checks a `.cube` file and keeps a copy under its hash. Throws, changing nothing,
    /// when the file is not a table this app can apply.
    static func importTable(at url: URL, role: LUTAssetRef.Role) throws -> LUTAssetRef {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= ColorCube.maximumBytes else {
            throw ColorCubeError(message: "\(url.lastPathComponent) is larger than 16 MB, too large for a colour table.")
        }
        let data = try Data(contentsOf: url)
        let cube = try ColorCube.parse(data)
        let sha = ColorCube.sha256(data)
        let stored = Self.url(for: sha)
        if !FileManager.default.fileExists(atPath: stored.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: stored, options: .atomic)
        }
        cache.store(sha, cube)
        return LUTAssetRef(sha256: sha, originalName: url.lastPathComponent, role: role)
    }

    /// The table with this hash, or nil when the store does not have it or the stored
    /// file no longer matches its name.
    static func cube(_ sha256: String) -> ColorCube? {
        if let cached = cache.value(sha256) { return cached }
        guard let data = try? Data(contentsOf: url(for: sha256)), ColorCube.sha256(data) == sha256,
              let cube = try? ColorCube.parse(data) else { return nil }
        cache.store(sha256, cube)
        return cube
    }

    static func has(_ sha256: String) -> Bool { cube(sha256) != nil }

    /// Takes a project's copy into the store when the store lacks it — opening a project
    /// made on another Mac. Only a file whose contents match the hash is taken.
    @discardableResult
    static func adopt(_ sha256: String, beside project: URL) -> Bool {
        if has(sha256) { return true }
        guard let ref = try? importTable(at: projectURL(for: sha256, beside: project), role: .pocket3DLogMToRec709) else { return false }
        return ref.sha256 == sha256
    }

    /// Copies the tables a project uses beside it. Returns the ones it could not copy.
    static func export(_ hashes: Set<String>, beside project: URL) -> [String] {
        var missing: [String] = []
        for sha in hashes.sorted() {
            let destination = projectURL(for: sha, beside: project)
            if let data = try? Data(contentsOf: destination), ColorCube.sha256(data) == sha { continue }
            do {
                let data = try Data(contentsOf: url(for: sha))
                guard ColorCube.sha256(data) == sha else { missing.append(sha); continue }
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: destination, options: .atomic)
            } catch { missing.append(sha) }
        }
        return missing
    }

    private static let cache = Cache<ColorCube>(limit: 8)
}

/// A small thread-safe memo; renderers ask from their own queues.
final class Cache<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Value] = [:]
    private var order: [String] = []
    private let limit: Int
    init(limit: Int) { self.limit = limit }

    func value(_ key: String) -> Value? { lock.lock(); defer { lock.unlock() }; return values[key] }

    func store(_ key: String, _ value: Value) {
        lock.lock(); defer { lock.unlock() }
        if values.updateValue(value, forKey: key) == nil { order.append(key) }
        while order.count > limit { values[order.removeFirst()] = nil }
    }
}

// MARK: - The colour stage

/// One recording's colour stage, compiled: the single table both renderers apply to
/// Rec.709-encoded RGB. Technical conversion and adjustments are baked together, so
/// ffmpeg and Core Image never run separately chosen filters that merely sound alike.
final class ColorRender: @unchecked Sendable {
    let cube: ColorCube
    /// Identifies the table: input conversion, algorithm and adjustments.
    let key: String
    init(cube: ColorCube, key: String) { self.cube = cube; self.key = key }

    /// RGBA floats for Core Image, built once.
    lazy var coreImageData: Data = cube.coreImageData

    /// The table as a file for ffmpeg's `lut3d`, in a temporary folder whose path needs
    /// no escaping in a filter graph. Named by the hash of its own text, so a file left
    /// by an older build that compiled the same settings differently is never reused.
    func cubeFile() throws -> URL {
        let lock = Self.fileLock
        lock.lock(); defer { lock.unlock() }
        if let file = writtenFile { return file }
        let text = Data(cube.cubeText(title: "YamVideo").utf8)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("YamVideo-colour", isDirectory: true)
        let file = folder.appendingPathComponent("\(ColorCube.sha256(text)).cube")
        if (try? Data(contentsOf: file)) != text {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try text.write(to: file, options: .atomic)
        }
        writtenFile = file
        return file
    }
    private var writtenFile: URL?
    private static let fileLock = NSLock()
}

/// What the colour stage does for a recording.
enum ColorStage {
    /// The picture passes through: standard colour and no adjustments, or Original view.
    case none
    case apply(ColorRender)
    /// Correction was asked for but cannot be done. Previews show the picture as recorded
    /// and say why; exports refuse rather than writing an uncorrected file.
    case unavailable(String)

    var render: ColorRender? { if case .apply(let render) = self { return render } else { return nil } }
    var problem: String? { if case .unavailable(let message) = self { return message } else { return nil } }
}

enum ColorPipeline {
    /// Grid used when there is no technical table to follow. Exposure and warmth are
    /// exact on any grid (a pure power law turns a linear gain into an encoded one);
    /// 33 keeps contrast and saturation within a code value of the exact maths.
    static let adjustmentGrid = 33

    private static let renders = Cache<ColorRender>(limit: 16)

    /// The profile in effect: the owner's choice, or what Auto can prove. A recording
    /// whose file cannot say stays as recorded.
    static func profile(_ settings: ClipColorSettings, info: MediaInfo, fileName: String) -> ColorInputProfile {
        settings.inputProfile == .auto
            ? info.inferredColorProfile(fileName: fileName).profile ?? .standard : settings.inputProfile
    }

    /// Compiles a recording's colour stage. `original` is the comparison view: it skips
    /// the stage entirely while HDR tone mapping, blur areas and the rest stay.
    static func stage(_ settings: ClipColorSettings, info: MediaInfo, fileName: String,
                      toneMapHDR: Bool, original: Bool = false) -> ColorStage {
        guard !original else { return .none }
        let adjustments = settings.adjustments
        var technical: (cube: ColorCube, sha: String)?
        if profile(settings, info: info, fileName: fileName) == .pocket3DLogM, settings.correctionEnabled {
            guard let ref = settings.technicalLUT, let cube = LUTStore.cube(ref.sha256) else {
                let name = settings.technicalLUT?.originalName ?? "conversion table"
                return .unavailable("The Pocket 3 conversion (\(name)) is missing from this Mac. Import it again to restore Natural colour.")
            }
            technical = (cube.unitDomain(), ref.sha256)
        }
        if info.isHDR, !toneMapHDR, !adjustments.isNeutral {
            return .unavailable("Colour adjustments work on standard colour. Turn on Convert HDR to SDR to use them on this HDR recording.")
        }
        guard technical != nil || !adjustments.isNeutral else { return .none }

        let size = technical?.cube.size ?? adjustmentGrid
        let parts = ["a\(settings.algorithmVersion)", technical?.sha ?? "standard", "n\(size)",
                     [adjustments.exposureEV, adjustments.warmth, adjustments.contrast, adjustments.saturation]
                        .map { String(format: "%.6f", $0) }.joined(separator: ",")]
        let key = ColorCube.sha256(Data(parts.joined(separator: "|").utf8))
        if let cached = renders.value(key) { return .apply(cached) }
        // The table's entries are clipped to 0–1: SDR delivery. ffmpeg clips there anyway,
        // converting to YUV straight after the table, while Core Image's video colour
        // space would carry a negative entry through as a visible tint. Clipping in the
        // table puts both renderers' boundary in the same place.
        let cube: ColorCube
        if let technical, adjustments.isNeutral {
            cube = technical.cube.clampedToUnit()
        } else {
            // At the technical table's own grid points `sample` returns its entries
            // exactly, so the baked table is the adjustment of the DJI conversion there.
            cube = ColorCube.build(size: size) { point in
                adjustments.apply(technical?.cube.sample(point) ?? point)
                    .clamped(lowerBound: SIMD3(repeating: 0), upperBound: SIMD3(repeating: 1))
            }
        }
        let render = ColorRender(cube: cube, key: key)
        renders.store(key, render)
        return .apply(render)
    }

    /// ffmpeg filters for the stage: to float RGB with the source's own matrix and range,
    /// the table with trilinear interpolation, then back to 10-bit Rec.709 YUV so no
    /// 8-bit step comes before the encoder. `matrix`/`fullRange` describe the frames as
    /// they arrive — after HDR tone mapping that is BT.709 limited range.
    static func ffmpegFilters(_ render: ColorRender, matrix: String, fullRange: Bool) throws -> [String] {
        let file = try render.cubeFile().path
        return [
            "scale=in_color_matrix=\(matrix):in_range=\(fullRange ? "pc" : "tv"):out_range=pc"
                + ":flags=accurate_rnd+full_chroma_int+full_chroma_inp,format=gbrpf32le",
            "lut3d=file='\(file)':interp=trilinear",
            "scale=out_color_matrix=bt709:out_range=tv:flags=accurate_rnd+full_chroma_int,format=yuv420p10le",
        ]
    }

    /// The stage's filters for one recording's export or preview, after any tone mapping.
    static func ffmpegFilters(_ stage: ColorStage, info: MediaInfo, toneMapped: Bool) throws -> [String] {
        guard let render = stage.render else { return [] }
        return try ffmpegFilters(render, matrix: toneMapped ? "bt709" : info.yuvMatrix,
                                 fullRange: toneMapped ? false : info.isFullRange)
    }

    /// What macOS reads Rec.709-tagged video as when a frame does not say. It is not
    /// `CGColorSpace.itur_709`: Core Media decodes 709 video with its own transfer
    /// function, and converting through the textbook curve moves mid-grey by some 19
    /// code values. The public constant arrived in macOS 15; the space itself is older.
    static let videoSpace = CGColorSpace(name: "kCGColorSpaceCoreMedia709" as CFString)
        ?? CGColorSpace(name: CGColorSpace.itur_709)!

    /// Applies the table to encoded values. Core Image works in linear light, so the
    /// filter converts into `space` around the lookup; given the frame's own decoding
    /// space, the table sees exactly the encoded RGB ffmpeg hands `lut3d`, and its
    /// output is read back the way the source would have been.
    static func apply(_ render: ColorRender, to image: CIImage, space: CGColorSpace?) -> CIImage {
        image.applyingFilter("CIColorCubeWithColorSpace", parameters: [
            "inputCubeDimension": render.cube.size,
            "inputCubeData": render.coreImageData,
            "inputColorSpace": space ?? videoSpace,
        ])
    }
}

extension VideoItem {
    /// This recording's colour stage under `settings`; `.none` until it is probed.
    func colorStage(_ settings: ExportSettings, original: Bool = false) -> ColorStage {
        guard let info else { return .none }
        return ColorPipeline.stage(color, info: info, fileName: name, toneMapHDR: settings.toneMapHDR, original: original)
    }

    /// The stage as ffmpeg filters, or none when it cannot be applied — for previews,
    /// which show the picture as recorded and leave the explanation to the inspector.
    func colorFilters(_ settings: ExportSettings, original: Bool = false) -> [String] {
        guard let info else { return [] }
        return (try? ColorPipeline.ffmpegFilters(colorStage(settings, original: original), info: info,
                                                 toneMapped: info.isHDR && settings.toneMapHDR)) ?? []
    }
}
