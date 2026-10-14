import AVFoundation

public enum ExportPreset: String, Codable, Sendable, CaseIterable, Identifiable {
    case webSafeH264
    case webSmallHEVC
    case archiveQuality

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .webSafeH264: return "Web Safe · H.264 1080p"
        case .webSmallHEVC: return "Web Small · HEVC 1080p"
        case .archiveQuality: return "Archive · highest quality"
        }
    }

    public var help: String {
        switch self {
        case .webSafeH264: return "Plays everywhere. The default for R2/your site."
        case .webSmallHEVC: return "~40% smaller, needs a modern browser."
        case .archiveQuality: return "Source resolution, best quality H.264."
        }
    }

    var avPreset: String {
        switch self {
        case .webSafeH264: return AVAssetExportPreset1920x1080
        case .webSmallHEVC: return AVAssetExportPresetHEVC1920x1080
        case .archiveQuality: return AVAssetExportPresetHighestQuality
        }
    }
}

public struct ExportResult: Sendable {
    public let outputURL: URL
    public let inputBytes: Int64
    public let outputBytes: Int64
    public let wasRemux: Bool
}

public enum ExportError: LocalizedError {
    case cannotReadSource(String)
    case exportFailed(String)

    public var errorDescription: String? {
        switch self {
        case .cannotReadSource(let detail): return "Can't read this file: \(detail)"
        case .exportFailed(let detail): return "Export failed: \(detail)"
        }
    }
}

/// MOV → MP4 the smart way: remux (stream copy, instant, lossless) whenever
/// the tracks are MP4-compatible, transcode only when they aren't. PLAN.md §2.4/§2.5.
public enum Exporter {

    /// True when a passthrough (no re-encode) export to .mp4 can work.
    public static func canRemuxToMP4(_ url: URL) async -> Bool {
        let asset = AVURLAsset(url: url)
        guard let session = AVAssetExportSession(
            asset: asset, presetName: AVAssetExportPresetPassthrough) else { return false }
        let types = await session.compatibleFileTypes
        return types.contains(.mp4)
    }

    /// Remux if possible, else transcode with `preset`. Reports 0–1 progress.
    public static func convertToMP4(
        _ inputURL: URL,
        outputURL: URL,
        preset: ExportPreset,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> ExportResult {
        let inputBytes = (try? FileManager.default
            .attributesOfItem(atPath: inputURL.path)[.size] as? Int64) ?? 0

        let remux = await canRemuxToMP4(inputURL)
        let presetName = remux ? AVAssetExportPresetPassthrough : preset.avPreset

        try await runExport(inputURL: inputURL, outputURL: outputURL,
                            presetName: presetName, progress: progress)

        let outputBytes = (try? FileManager.default
            .attributesOfItem(atPath: outputURL.path)[.size] as? Int64) ?? 0
        return ExportResult(outputURL: outputURL, inputBytes: inputBytes,
                            outputBytes: outputBytes, wasRemux: remux)
    }

    /// Force a transcode with `preset` (used when remux output is unwanted,
    /// e.g. the source is a huge high-bitrate recording worth shrinking).
    public static func transcodeToMP4(
        _ inputURL: URL,
        outputURL: URL,
        preset: ExportPreset,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> ExportResult {
        let inputBytes = (try? FileManager.default
            .attributesOfItem(atPath: inputURL.path)[.size] as? Int64) ?? 0
        try await runExport(inputURL: inputURL, outputURL: outputURL,
                            presetName: preset.avPreset, progress: progress)
        let outputBytes = (try? FileManager.default
            .attributesOfItem(atPath: outputURL.path)[.size] as? Int64) ?? 0
        return ExportResult(outputURL: outputURL, inputBytes: inputBytes,
                            outputBytes: outputBytes, wasRemux: false)
    }

    private static func runExport(
        inputURL: URL,
        outputURL: URL,
        presetName: String,
        progress: (@Sendable (Double) -> Void)?
    ) async throws {
        let asset = AVURLAsset(url: inputURL)
        guard let session = AVAssetExportSession(asset: asset, presetName: presetName) else {
            throw ExportError.cannotReadSource("no export session for preset \(presetName)")
        }
        session.shouldOptimizeForNetworkUse = true   // == ffmpeg's +faststart

        try? FileManager.default.removeItem(at: outputURL)

        let monitor: Task<Void, Never>? = progress.map { report in
            Task {
                for await state in session.states(updateInterval: 0.25) {
                    if case .exporting(let p) = state {
                        report(p.fractionCompleted)
                    }
                }
            }
        }
        defer { monitor?.cancel() }

        do {
            try await session.export(to: outputURL, as: .mp4)
        } catch {
            throw ExportError.exportFailed(error.localizedDescription)
        }
        progress?(1.0)
    }

    /// "name.mp4" beside the input, avoiding collisions ("name 2.mp4", …).
    public static func defaultOutputURL(for input: URL, ext: String = "mp4") -> URL {
        let dir = input.deletingLastPathComponent()
        let base = input.deletingPathExtension().lastPathComponent
        var candidate = dir.appendingPathComponent("\(base).\(ext)")
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = dir.appendingPathComponent("\(base) \(n).\(ext)")
            n += 1
        }
        return candidate
    }
}
