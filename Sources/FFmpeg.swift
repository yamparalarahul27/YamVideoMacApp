import Foundation

struct FFmpegError: LocalizedError {
    var message: String
    var errorDescription: String? { message }
}

enum FFmpeg {
    // MARK: - Locating the binaries

    private static let overrideKey = "ffmpegFolderOverride"

    /// Folders searched for ffmpeg/ffprobe. A GUI app does not inherit the shell's PATH,
    /// so the usual install locations are probed explicitly.
    private static var searchFolders: [String] {
        var folders: [String] = []
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("bin").path {
            folders.append(bundled)
        }
        if let override = UserDefaults.standard.string(forKey: overrideKey) {
            folders.append(override)
        }
        folders += ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin", "/usr/bin"]
        return folders
    }

    static func locate(_ tool: String) -> String? {
        for folder in searchFolders {
            let path = (folder as NSString).appendingPathComponent(tool)
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    static var ffmpegPath: String? { locate("ffmpeg") }
    static var ffprobePath: String? { locate("ffprobe") }
    static var isAvailable: Bool { ffmpegPath != nil && ffprobePath != nil }

    /// Remembers a user-chosen folder containing ffmpeg (used by the "Locate…" button).
    static func setOverrideFolder(_ url: URL) {
        UserDefaults.standard.set(url.path, forKey: overrideKey)
    }

    static func version() async -> String? {
        guard let ffmpeg = ffmpegPath else { return nil }
        guard let result = try? await Shell.run(ffmpeg, ["-hide_banner", "-version"]) else { return nil }
        return result.stdoutText.split(separator: "\n").first.map(String.init)
    }

    // MARK: - Probing

    static func probe(url: URL) async throws -> MediaInfo {
        guard let ffprobe = ffprobePath else {
            throw FFmpegError(message: "ffprobe was not found.")
        }
        let result = try await Shell.run(ffprobe, [
            "-v", "error",
            "-print_format", "json",
            "-show_format", "-show_streams",
            url.path,
        ])
        guard result.status == 0 else {
            throw FFmpegError(message: result.stderrText.isEmpty
                ? "ffprobe could not read this file."
                : result.stderrText.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        guard
            let root = try JSONSerialization.jsonObject(with: result.stdout) as? [String: Any],
            let streams = root["streams"] as? [[String: Any]]
        else {
            throw FFmpegError(message: "Unexpected ffprobe output.")
        }

        guard let video = streams.first(where: { $0["codec_type"] as? String == "video" }) else {
            throw FFmpegError(message: "This file has no video track.")
        }

        let codedWidth = (video["width"] as? Int) ?? 0
        let codedHeight = (video["height"] as? Int) ?? 0
        guard codedWidth > 0, codedHeight > 0 else {
            throw FFmpegError(message: "Could not determine the video dimensions.")
        }

        let rotation = rotationDegrees(from: video)
        let swapped = abs(rotation) == 90 || abs(rotation) == 270
        let audio = streams.first { $0["codec_type"] as? String == "audio" }

        var duration = doubleValue(video["duration"]) ?? 0
        if duration <= 0, let format = root["format"] as? [String: Any] {
            duration = doubleValue(format["duration"]) ?? 0
        }

        return MediaInfo(
            width: swapped ? codedHeight : codedWidth,
            height: swapped ? codedWidth : codedHeight,
            duration: duration,
            videoCodec: (video["codec_name"] as? String) ?? "unknown",
            audioCodec: audio?["codec_name"] as? String,
            fps: parseRate(video["avg_frame_rate"]) ?? parseRate(video["r_frame_rate"]) ?? 0,
            rotation: rotation
        )
    }

    private static func rotationDegrees(from stream: [String: Any]) -> Int {
        if let sideData = stream["side_data_list"] as? [[String: Any]] {
            for entry in sideData {
                if let rotation = doubleValue(entry["rotation"]) {
                    return Int(rotation.rounded()) % 360
                }
            }
        }
        if let tags = stream["tags"] as? [String: Any], let rotation = doubleValue(tags["rotate"]) {
            return Int(rotation.rounded()) % 360
        }
        return 0
    }

    private static func doubleValue(_ any: Any?) -> Double? {
        if let d = any as? Double { return d }
        if let i = any as? Int { return Double(i) }
        if let s = any as? String { return Double(s) }
        return nil
    }

    private static func parseRate(_ any: Any?) -> Double? {
        guard let text = any as? String else { return nil }
        let parts = text.split(separator: "/")
        if parts.count == 2, let n = Double(parts[0]), let d = Double(parts[1]), d != 0 {
            return n / d
        }
        return Double(text)
    }

    // MARK: - Thumbnails

    /// Grabs a single frame as PNG data. Rotation metadata is applied, so the frame
    /// matches the coordinate space the crop rectangle is expressed in.
    static func thumbnail(
        url: URL,
        at seconds: Double,
        duration: Double = 0,
        regions: [CGRect] = [],
        style: BlurStyle = .blur,
        strength: Double = 24,
        maxWidth: Int = 1400
    ) async throws -> Data {
        guard let ffmpeg = ffmpegPath else {
            throw FFmpegError(message: "ffmpeg was not found.")
        }
        // Seeking to (or past) the last frame's timestamp decodes nothing, so keep
        // a little headroom when the scrubber is at the very end of the clip.
        var seek = max(0, seconds)
        if duration > 0 {
            seek = min(seek, max(0, duration - 0.25))
        }

        // The preview shows the whole frame (the crop is drawn as an overlay), but blur
        // regions are baked in by the same graph builder the export uses.
        let graph = filterGraph(
            regions: regions,
            style: style,
            strength: strength,
            tail: ["scale='min(\(maxWidth),iw)':-2:flags=bilinear"]
        )

        func grab(_ time: Double) async throws -> Data {
            var args = [
                "-hide_banner", "-loglevel", "error",
                "-ss", String(format: "%.3f", time),
                "-i", url.path,
                "-frames:v", "1",
            ]
            if let graph {
                if graph.isComplex, let label = graph.outputLabel {
                    args += ["-filter_complex", graph.spec, "-map", "[\(label)]"]
                } else {
                    args += ["-vf", graph.spec]
                }
            }
            args += ["-f", "image2pipe", "-vcodec", "png", "-"]
            let result = try await Shell.run(ffmpeg, args)
            guard result.status == 0, !result.stdout.isEmpty else {
                throw FFmpegError(message: result.stderrText.isEmpty
                    ? "Could not read a frame at \(formatDuration(time))."
                    : result.stderrText.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            return result.stdout
        }

        do {
            return try await grab(seek)
        } catch {
            // Broken or misreported durations: fall back to the first frame.
            guard seek > 0, !Task.isCancelled else { throw error }
            return try await grab(0)
        }
    }

    // MARK: - Filter graph

    /// A video filter chain, either simple (`-vf`) or a graph needing `-filter_complex`.
    struct FilterGraph {
        var spec: String
        var isComplex: Bool
        /// Output pad label when complex, so the caller can `-map` it.
        var outputLabel: String?
    }

    /// The filter that obscures one already-cropped region.
    private static func obscureFilter(style: BlurStyle, strength: Double, size: CGSize) -> String {
        switch style {
        case .blur:
            return "gblur=sigma=\(max(1, Int(strength.rounded())))"
        case .pixelate:
            // Downscale then nearest-neighbour back up: exact sizes are computed here so
            // ffmpeg never has to round a fractional block count.
            let block = max(2.0, strength / 2)
            let w = max(1, Int((size.width / block).rounded(.down)))
            let h = max(1, Int((size.height / block).rounded(.down)))
            return "scale=\(w):\(h),scale=\(Int(size.width)):\(Int(size.height)):flags=neighbor"
        case .black:
            return "drawbox=0:0:iw:ih:color=black:t=fill"
        }
    }

    /// Builds the video filter graph: obscured regions first (so their coordinates stay in
    /// full-frame space), then `tail` — the crop and scale steps.
    static func filterGraph(
        regions: [CGRect],
        style: BlurStyle,
        strength: Double,
        tail: [String]
    ) -> FilterGraph? {
        guard !regions.isEmpty else {
            return tail.isEmpty
                ? nil
                : FilterGraph(spec: tail.joined(separator: ","), isComplex: false, outputLabel: nil)
        }

        // A solid fill needs no second copy of the frame — drawbox paints in place.
        if style == .black {
            let boxes = regions.map {
                "drawbox=\(Int($0.minX)):\(Int($0.minY)):\(Int($0.width)):\(Int($0.height)):color=black:t=fill"
            }
            return FilterGraph(spec: (boxes + tail).joined(separator: ","),
                               isComplex: false, outputLabel: nil)
        }

        // Split the frame, blur a copy of each region, and composite them back on top.
        var parts: [String] = []
        let taps = regions.indices.map { "t\($0)" }
        parts.append("[0:v]split=\(regions.count + 1)[base]" + taps.map { "[\($0)]" }.joined())

        for (index, region) in regions.enumerated() {
            let crop = "crop=\(Int(region.width)):\(Int(region.height)):\(Int(region.minX)):\(Int(region.minY))"
            let obscure = obscureFilter(style: style, strength: strength, size: region.size)
            parts.append("[t\(index)]\(crop),\(obscure)[b\(index)]")
        }

        var current = "base"
        for (index, region) in regions.enumerated() {
            let isLast = index == regions.count - 1
            let label = isLast ? (tail.isEmpty ? "vout" : "ov") : "o\(index)"
            parts.append("[\(current)][b\(index)]overlay=\(Int(region.minX)):\(Int(region.minY))[\(label)]")
            current = label
        }

        if !tail.isEmpty {
            parts.append("[\(current)]" + tail.joined(separator: ",") + "[vout]")
        }

        return FilterGraph(spec: parts.joined(separator: ";"), isComplex: true, outputLabel: "vout")
    }

    // MARK: - Export

    /// Builds the ffmpeg argument list. Exposed so the UI can show the exact command.
    static func exportArguments(
        input: URL,
        output: URL,
        info: MediaInfo,
        crop: CGRect,
        regions: [CGRect] = [],
        settings: ExportSettings
    ) -> [String] {
        let cropRect = crop.evenClamped(in: info.fullFrame)
        var tail: [String] = []

        if cropRect.integral != info.fullFrame.integral {
            tail.append("crop=\(Int(cropRect.width)):\(Int(cropRect.height)):\(Int(cropRect.minX)):\(Int(cropRect.minY))")
        }

        if let scaled = scaledSize(for: cropRect.size, limit: settings.sizeLimit) {
            tail.append("scale=\(Int(scaled.width)):\(Int(scaled.height)):flags=lanczos")
        }

        var args = ["-hide_banner", "-nostdin", "-y", "-i", input.path]

        let graph = filterGraph(
            regions: regions.map { $0.evenClamped(in: info.fullFrame) },
            style: settings.blurStyle,
            strength: settings.blurStrength,
            tail: tail
        )

        if let graph {
            if graph.isComplex, let label = graph.outputLabel {
                // Explicit maps: -filter_complex disables ffmpeg's automatic stream selection.
                args += ["-filter_complex", graph.spec, "-map", "[\(label)]"]
                if info.hasAudio, settings.audio != .none {
                    args += ["-map", "0:a:0"]
                }
            } else {
                args += ["-vf", graph.spec]
            }
        }

        switch settings.encoder {
        case .x264:
            args += ["-c:v", "libx264", "-crf", String(settings.crf), "-preset", settings.preset]
        case .h264VT:
            args += ["-c:v", "h264_videotoolbox", "-q:v", String(settings.vtQuality)]
        case .hevcVT:
            args += ["-c:v", "hevc_videotoolbox", "-q:v", String(settings.vtQuality), "-tag:v", "hvc1"]
        }
        args += ["-pix_fmt", "yuv420p"]

        switch settings.audio {
        case .aac:
            if info.hasAudio { args += ["-c:a", "aac", "-b:a", "192k"] } else { args += ["-an"] }
        case .copy:
            if info.hasAudio { args += ["-c:a", "copy"] } else { args += ["-an"] }
        case .none:
            args += ["-an"]
        }

        args += ["-movflags", "+faststart", "-map_metadata", "0"]
        args += ["-progress", "pipe:1", "-nostats"]
        args.append(output.path)
        return args
    }

    /// Output size after applying the long-side limit. Nil when no rescale is needed.
    static func scaledSize(for size: CGSize, limit: SizeLimit) -> CGSize? {
        guard limit != .original else { return nil }
        let target = CGFloat(limit.rawValue)
        let longSide = max(size.width, size.height)
        guard longSide > target else { return nil }
        let scale = target / longSide
        func even(_ v: CGFloat) -> CGFloat { max(2, (v * 0.5).rounded() * 2) }
        return CGSize(width: even(size.width * scale), height: even(size.height * scale))
    }

    static func export(
        input: URL,
        output: URL,
        info: MediaInfo,
        crop: CGRect,
        regions: [CGRect] = [],
        settings: ExportSettings,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws {
        guard let ffmpeg = ffmpegPath else {
            throw FFmpegError(message: "ffmpeg was not found.")
        }
        let args = exportArguments(input: input, output: output, info: info,
                                   crop: crop, regions: regions, settings: settings)
        let duration = info.duration

        let result = try await Shell.run(ffmpeg, args) { line in
            guard duration > 0 else { return }
            let parts = line.split(separator: "=", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard parts.count == 2 else { return }
            if parts[0] == "out_time_us" || parts[0] == "out_time_ms" {
                // Both keys report microseconds in current ffmpeg builds.
                guard let micros = Double(parts[1]), micros >= 0 else { return }
                onProgress(min(0.999, micros / 1_000_000 / duration))
            }
        }

        if Task.isCancelled {
            try? FileManager.default.removeItem(at: output)
            throw CancellationError()
        }

        guard result.status == 0 else {
            try? FileManager.default.removeItem(at: output)
            let stderr = result.stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
            let tail = stderr.split(separator: "\n").suffix(4).joined(separator: "\n")
            throw FFmpegError(message: tail.isEmpty ? "ffmpeg exited with code \(result.status)." : tail)
        }
        onProgress(1)
    }

    /// A non-colliding `.mp4` path for the given source file.
    static func outputURL(for input: URL, settings: ExportSettings) -> URL {
        let folder = settings.outputFolder ?? input.deletingLastPathComponent()
        let stem = input.deletingPathExtension().lastPathComponent
        let suffix = settings.suffix
        var candidate = folder.appendingPathComponent(stem + suffix).appendingPathExtension("mp4")

        if candidate.path.compare(input.path, options: .caseInsensitive) != .orderedSame,
           !FileManager.default.fileExists(atPath: candidate.path) {
            return candidate
        }
        var counter = 2
        repeat {
            candidate = folder
                .appendingPathComponent("\(stem)\(suffix)-\(counter)")
                .appendingPathExtension("mp4")
            counter += 1
        } while FileManager.default.fileExists(atPath: candidate.path) && counter < 1000
        return candidate
    }
}
