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
        // Homebrew's plain `ffmpeg` is now a slim build with no libwebp; the full one lives
        // in `ffmpeg-full`, which is keg-only and so never appears in bin. Prefer it when
        // it is installed — same ffmpeg, strictly more encoders — but never over an
        // explicit override.
        folders += ["/opt/homebrew/opt/ffmpeg-full/bin", "/usr/local/opt/ffmpeg-full/bin"]
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
        encoderCache.clear()
        filterCache.clear()
    }

    static func version() async -> String? {
        guard let ffmpeg = ffmpegPath else { return nil }
        guard let result = try? await Shell.run(ffmpeg, ["-hide_banner", "-version"]) else { return nil }
        return result.stdoutText.split(separator: "\n").first.map(String.init)
    }

    // MARK: - Build capabilities

    /// Keeps the lock inside synchronous methods, the way Shell's boxes do — taking one
    /// directly in an async function is an error under the Swift 6 language mode.
    private final class NameCache: @unchecked Sendable {
        private let lock = NSLock()
        private var names: Set<String>?

        var value: Set<String>? {
            lock.lock(); defer { lock.unlock() }
            return names
        }
        func store(_ value: Set<String>) { lock.lock(); names = value; lock.unlock() }
        func clear() { lock.lock(); names = nil; lock.unlock() }
    }

    private static let encoderCache = NameCache()
    private static let filterCache = NameCache()

    /// Encoder names this ffmpeg was built with. Nothing can be assumed here: Homebrew's
    /// stock bottle has libwebp, but slimmed-down and hand-rolled builds often do not, and
    /// asking for a missing encoder only fails once the export is already under way.
    static func encoders() async -> Set<String> {
        if let cached = encoderCache.value { return cached }

        guard let ffmpeg = ffmpegPath,
              let result = try? await Shell.run(ffmpeg, ["-hide_banner", "-encoders"]),
              result.status == 0
        else { return [] }  // Not cached: a later lookup should get a second chance.

        // Rows read "  V....D gif   GIF (Graphics Interchange Format)"; the legend above
        // them uses the same shape but with "=" as the second field.
        var names: Set<String> = []
        for line in result.stdoutText.split(separator: "\n") {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 2, fields[0].count == 6, fields[1] != "=" else { continue }
            names.insert(String(fields[1]))
        }

        encoderCache.store(names)
        return names
    }

    static func supports(_ encoder: String) async -> Bool {
        await encoders().contains(encoder)
    }

    /// Animated WebP needs libwebp, which is an optional ffmpeg build flag.
    static func supportsWebP() async -> Bool { await supports("libwebp") }

    /// Filter names this ffmpeg was built with. Same story as the encoders: `zscale`
    /// only exists when the build enabled libzimg, and there is no way to know but ask.
    static func filters() async -> Set<String> {
        if let cached = filterCache.value { return cached }

        guard let ffmpeg = ffmpegPath,
              let result = try? await Shell.run(ffmpeg, ["-hide_banner", "-filters"]),
              result.status == 0
        else { return [] }  // Not cached: a later lookup should get a second chance.

        // Rows read "  ... zscale            V->V       Apply resizing…"; the legend above
        // them has "=" in the second field, and no "->" arrow in the third.
        var names: Set<String> = []
        for line in result.stdoutText.split(separator: "\n") {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard fields.count >= 3, fields[0].count == 3,
                  fields[1] != "=", fields[2].contains("->") else { continue }
            names.insert(fields[1])
        }

        filterCache.store(names)
        return names
    }

    /// Tone mapping needs zimg for the colourspace conversions either side of it.
    /// Homebrew's stock ffmpeg usually has it; slim and hand-rolled builds often do not.
    static func supportsToneMapping() async -> Bool {
        let names = await filters()
        return names.contains("zscale") && names.contains("tonemap")
    }

    /// Burning subtitles in needs libass, which is another optional build flag.
    static func supportsSubtitles() async -> Bool {
        await filters().contains("subtitles")
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
            fpsExpression: frameRateExpression(video),
            rotation: rotation,
            colorTransfer: video["color_transfer"] as? String
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

    /// The frame rate verbatim ("30000/1001"), so it can be handed back to ffmpeg exactly.
    private static func frameRateExpression(_ stream: [String: Any]) -> String {
        for key in ["avg_frame_rate", "r_frame_rate"] {
            if let text = stream[key] as? String, let rate = parseRate(text), rate > 0 {
                return text
            }
        }
        return "30"
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
        toneMap: Bool = false,
        subtitles: URL? = nil,
        subtitleStyle: String = ExportSettings().subtitleForceStyle,
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
        // regions, tone mapping and captions are baked in by the same graph builder the
        // export uses, in the same order, so the two cannot drift apart.
        var tail = ["scale='min(\(maxWidth),iw)':-2:flags=bilinear"]
        if let subtitles, let staged = try? stageSubtitles(subtitles) {
            tail.append(subtitlesFilter(staged: staged, forceStyle: subtitleStyle))
        }

        let graph = filterGraph(
            head: toneMap ? [toneMapChain] : [],
            regions: regions,
            style: style,
            strength: strength,
            tail: tail
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

    /// HLG or PQ down to Rec.709 SDR.
    ///
    /// Tone mapping is only meaningful in linear light, so the chain linearises, works in
    /// float RGB, maps, and converts back. The float RGB step is not decoration: doing this
    /// in subsampled YUV would resample chroma twice and shift colour.
    ///
    /// This runs at the *head* of the graph, before the blur regions, so every later stage
    /// — and the preview, which shares this builder — sees the same SDR frame the export
    /// writes.
    static let toneMapChain =
        "zscale=t=linear:npl=100,format=gbrpf32le,zscale=p=bt709,"
        + "tonemap=tonemap=hable:desat=0,zscale=t=bt709:m=bt709:r=tv,format=yuv420p"

    /// Filters that have to run before anything else. Empty for an ordinary SDR clip.
    static func videoHead(info: MediaInfo, settings: ExportSettings) -> [String] {
        guard info.isHDR, settings.toneMapHDR else { return [] }
        return [toneMapChain]
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
        head: [String] = [],
        regions: [CGRect],
        style: BlurStyle,
        strength: Double,
        tail: [String]
    ) -> FilterGraph? {
        guard !regions.isEmpty else {
            let chain = head + tail
            return chain.isEmpty
                ? nil
                : FilterGraph(spec: chain.joined(separator: ","), isComplex: false, outputLabel: nil)
        }

        // A solid fill needs no second copy of the frame — drawbox paints in place.
        if style == .black {
            let boxes = regions.map {
                "drawbox=\(Int($0.minX)):\(Int($0.minY)):\(Int($0.width)):\(Int($0.height)):color=black:t=fill"
            }
            return FilterGraph(spec: (head + boxes + tail).joined(separator: ","),
                               isComplex: false, outputLabel: nil)
        }

        // Split the frame, blur a copy of each region, and composite them back on top.
        var parts: [String] = []
        let taps = regions.indices.map { "t\($0)" }
        // The head runs once, before the split, so every copy of the frame shares it.
        let headChain = head.isEmpty ? "" : head.joined(separator: ",") + ","
        parts.append("[0:v]\(headChain)split=\(regions.count + 1)[base]"
                     + taps.map { "[\($0)]" }.joined())

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

    // MARK: - Zoom

    private static func num(_ value: Double) -> String { String(format: "%.4f", value) }

    /// 0 before the shot, eased up to 1 across the ease-in, 1 through the hold, eased back
    /// down, 0 after. Smoothstep (3u² − 2u³) so the motion starts and stops gently.
    private static func rampExpression(_ shot: ZoomShot) -> String {
        let ease = ZoomShot.ease
        let t0 = shot.start
        let t1 = t0 + ease
        let t2 = t1 + shot.hold
        let t3 = t2 + ease
        let up = "(3*pow((in_time-\(num(t0)))/\(num(ease)),2)-2*pow((in_time-\(num(t0)))/\(num(ease)),3))"
        let down = "(3*pow((\(num(t3))-in_time)/\(num(ease)),2)-2*pow((\(num(t3))-in_time)/\(num(ease)),3))"
        return "if(lt(in_time,\(num(t0))),0,"
            + "if(lt(in_time,\(num(t1))),\(up),"
            + "if(lt(in_time,\(num(t2))),1,"
            + "if(lt(in_time,\(num(t3))),\(down),0))))"
    }

    /// Animated push-in built as a single zoompan filter.
    ///
    /// `frame` is the size *after* cropping and `cropOrigin` its offset, since shot targets
    /// are stored against the full frame. Output size stays equal to the input size so the
    /// window maths cannot be thrown off by a simultaneous rescale — the size limit is a
    /// separate scale step afterwards.
    static func zoomFilter(
        shots: [ZoomShot],
        frame: CGSize,
        cropOrigin: CGPoint,
        fpsExpression: String
    ) -> String? {
        let active = shots.filter { $0.level > 1 && $0.hold >= 0 }
        guard !active.isEmpty, frame.width > 0, frame.height > 0 else { return nil }

        var zoomTerms = ["1"]
        var centreX = [num(frame.width / 2)]
        var centreY = [num(frame.height / 2)]

        for shot in active.sorted(by: { $0.start < $1.start }) {
            let ramp = rampExpression(shot)
            // Targets are stored in full-frame coordinates; convert to the cropped frame.
            let targetX = shot.target.x - cropOrigin.x
            let targetY = shot.target.y - cropOrigin.y
            zoomTerms.append("(\(num(shot.level - 1)))*(\(ramp))")
            centreX.append("(\(num(targetX - frame.width / 2)))*(\(ramp))")
            centreY.append("(\(num(targetY - frame.height / 2)))*(\(ramp))")
        }

        // Shots never overlap, so summing the ramps leaves exactly one active at a time.
        let z = zoomTerms.joined(separator: "+")
        let x = "max(0,min((\(centreX.joined(separator: "+")))-iw/(2*zoom),iw-iw/zoom))"
        let y = "max(0,min((\(centreY.joined(separator: "+")))-ih/(2*zoom),ih-ih/zoom))"

        return "zoompan=z='\(z)':x='\(x)':y='\(y)':d=1"
            + ":s=\(Int(frame.width))x\(Int(frame.height)):fps=\(fpsExpression)"
    }

    // MARK: - Subtitles

    /// Subtitle files the `subtitles` filter can burn in as they are.
    static let subtitleExtensions = ["srt", "vtt", "ass", "ssa"]

    private static let safeNameCharacters = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
    private static let safeExtensionCharacters = Set("abcdefghijklmnopqrstuvwxyz")

    /// A filter-safe path for a subtitle file.
    ///
    /// `subtitles=` takes its filename as a filter argument, and the parsers between here
    /// and libass treat `:` as an option separator, `,` and `;` as graph separators, and
    /// `'` and `\\` as quoting — every one of which is a legal character in a macOS
    /// filename. Escaping three parser levels by hand is a bug waiting to happen, so the
    /// file is copied to a name built only from characters none of them care about.
    ///
    /// The name is derived from the source path rather than random, so the command shown
    /// in the sidebar is the one that actually runs — the same reason `paletteURL` is.
    static func stagedSubtitlesURL(for url: URL) -> URL {
        // FNV-1a over the full path. Swift's own hashValue is seeded per process, so it
        // would give a different name every launch and let two different files collide
        // across runs; this does not.
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in url.path.utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01B3
        }

        let stem = String(url.deletingPathExtension().lastPathComponent
            .filter { safeNameCharacters.contains($0) }
            .prefix(40))
        let ext = url.pathExtension.lowercased().filter { safeExtensionCharacters.contains($0) }

        var name = "yamvideo-subs-" + String(hash, radix: 16)
        if !stem.isEmpty { name += "-" + stem }
        return URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(name)
            .appendingPathExtension(ext.isEmpty ? "srt" : ext)
    }

    /// Copies a subtitle file to its staged path, skipping the copy when it is current.
    ///
    /// The staged copy is deliberately not deleted afterwards: it is a few kilobytes, the
    /// preview re-reads it on every refresh, and the temporary directory is the system's
    /// to reclaim. The GIF palette is deleted because it is large and rebuilt every time.
    @discardableResult
    static func stageSubtitles(_ url: URL) throws -> URL {
        let manager = FileManager.default
        guard manager.fileExists(atPath: url.path) else {
            throw FFmpegError(message: "The subtitle file \(url.lastPathComponent) is no longer there. "
                + "Choose it again, or clear it in the Subtitles section.")
        }

        let staged = stagedSubtitlesURL(for: url)
        let modified = { (candidate: URL) -> Date? in
            try? candidate.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        }
        if let source = modified(url), let copy = modified(staged), copy >= source {
            return staged
        }

        try? manager.removeItem(at: staged)
        do {
            try manager.copyItem(at: url, to: staged)
        } catch {
            throw FFmpegError(message: "Could not read \(url.lastPathComponent): \(error.localizedDescription)")
        }
        return staged
    }

    /// The burn-in step, given an already-staged file.
    ///
    /// `force_style` is quoted because its fields are comma-separated, and an unquoted
    /// comma ends the filter rather than the style. The filename needs no quoting because
    /// staging already removed everything that would have needed it.
    static func subtitlesFilter(staged: URL, forceStyle: String) -> String {
        "subtitles=\(staged.path):force_style='\(forceStyle)'"
    }

    // MARK: - Export

    /// Everything applied after the blur regions: crop, zoom, frame-rate cut, downscale.
    private static func videoTail(
        info: MediaInfo,
        crop cropRect: CGRect,
        zoomShots: [ZoomShot],
        settings: ExportSettings,
        subtitles: URL? = nil
    ) -> [String] {
        var tail: [String] = []

        if cropRect.integral != info.fullFrame.integral {
            tail.append("crop=\(Int(cropRect.width)):\(Int(cropRect.height)):\(Int(cropRect.minX)):\(Int(cropRect.minY))")
        }

        // Zoom runs on the cropped frame, before any downscale.
        if let zoom = zoomFilter(shots: zoomShots, frame: cropRect.size,
                                 cropOrigin: cropRect.origin, fpsExpression: info.fpsExpression) {
            tail.append(zoom)
        }

        // Thinning frames out is the biggest saving a GIF or WebP has. It goes after the
        // zoom (zoompan re-times to the source rate, so an earlier fps would be undone)
        // and before the scale, so fewer frames need resampling. Never above the source
        // rate — duplicated frames only add bytes.
        if settings.format.isAnimation, let rate = settings.frameRate.value,
           info.fps <= 0 || rate < info.fps {
            tail.append("fps=\(Int(rate))")
        }

        if let scaled = scaledSize(for: cropRect.size, limit: settings.sizeLimit) {
            tail.append("scale=\(Int(scaled.width)):\(Int(scaled.height)):flags=lanczos")
        }

        // Subtitles are burned last, on purpose. Ahead of the scale the text would be
        // resampled along with the picture; ahead of the zoom it would be magnified with
        // it; ahead of the blur areas it could be obscured by one.
        if let subtitles {
            tail.append(subtitlesFilter(staged: stagedSubtitlesURL(for: subtitles),
                                        forceStyle: settings.subtitleForceStyle))
        }
        return tail
    }

    /// Wraps `graph` in the input/output maps ffmpeg needs, honouring whether it turned out
    /// simple enough for `-vf`.
    private static func mapped(_ graph: FilterGraph?, audio: Bool) -> [String] {
        guard let graph else { return [] }
        if graph.isComplex, let label = graph.outputLabel {
            // Explicit maps: -filter_complex disables ffmpeg's automatic stream selection.
            var args = ["-filter_complex", graph.spec, "-map", "[\(label)]"]
            if audio { args += ["-map", "0:a:0"] }
            return args
        }
        return ["-vf", graph.spec]
    }

    /// Builds the ffmpeg argument list. Exposed so the UI can show the exact command.
    ///
    /// `palette` is the GIF second pass: the frames are mapped through the palette PNG
    /// written by `paletteArguments` instead of ffmpeg picking colours frame by frame.
    static func exportArguments(
        input: URL,
        output: URL,
        info: MediaInfo,
        crop: CGRect,
        regions: [CGRect] = [],
        zoomShots: [ZoomShot] = [],
        settings: ExportSettings,
        subtitles: URL? = nil,
        palette: URL? = nil,
        loudness: LoudnessMeasurement? = nil
    ) -> [String] {
        let cropRect = crop.evenClamped(in: info.fullFrame)
        let tail = videoTail(info: info, crop: cropRect, zoomShots: zoomShots,
                             settings: settings, subtitles: subtitles)

        var args = ["-hide_banner", "-nostdin", "-y", "-i", input.path]
        if let palette { args += ["-i", palette.path] }

        let graph = filterGraph(
            head: videoHead(info: info, settings: settings),
            regions: regions.map { $0.evenClamped(in: info.fullFrame) },
            style: settings.blurStyle,
            strength: settings.blurStrength,
            tail: tail
        )

        if palette != nil {
            // diff_mode=rectangle leaves untouched areas of the frame alone, which is
            // what makes a screen-recording GIF compress at all.
            let use = "paletteuse=dither=\(settings.gifDither.filterValue):diff_mode=rectangle"
            let spec: String
            if let graph, graph.isComplex, let label = graph.outputLabel {
                spec = "\(graph.spec);[\(label)][1:v]\(use)[gif]"
            } else if let graph {
                spec = "[0:v]\(graph.spec)[pre];[pre][1:v]\(use)[gif]"
            } else {
                spec = "[0:v][1:v]\(use)[gif]"
            }
            args += ["-filter_complex", spec, "-map", "[gif]"]
        } else {
            args += mapped(graph, audio: info.hasAudio && settings.audio != .none
                           && !settings.format.isAnimation)
        }

        switch settings.format {
        case .mp4:
            switch settings.encoder {
            case .x264:
                args += ["-c:v", "libx264", "-crf", String(settings.crf), "-preset", settings.preset]
            case .h264VT:
                args += ["-c:v", "h264_videotoolbox", "-q:v", String(settings.vtQuality)]
            case .hevcVT:
                args += ["-c:v", "hevc_videotoolbox", "-q:v", String(settings.vtQuality), "-tag:v", "hvc1"]
            }
            args += ["-pix_fmt", "yuv420p"]

            // The frames are Rec.709 now. Saying so matters: without these the muxer
            // copies the source's HDR tags onto SDR pixels and players stretch them back.
            if !videoHead(info: info, settings: settings).isEmpty {
                args += ["-color_primaries", "bt709", "-color_trc", "bt709", "-colorspace", "bt709"]
            }

            switch settings.audio {
            case .aac:
                if info.hasAudio { args += ["-c:a", "aac", "-b:a", "192k"] } else { args += ["-an"] }
            case .normalised:
                if info.hasAudio {
                    var filter = "loudnorm=\(Loudness.filterTargets)"
                    if let loudness { filter += ":" + loudness.filterArguments }
                    // loudnorm resamples to 192 kHz internally and will happily hand that
                    // rate to the encoder, so the output rate is pinned back explicitly.
                    args += ["-af", filter, "-c:a", "aac", "-b:a", "192k", "-ar", "48000"]
                } else {
                    args += ["-an"]
                }
            case .copy:
                if info.hasAudio { args += ["-c:a", "copy"] } else { args += ["-an"] }
            case .none:
                args += ["-an"]
            }

            args += ["-movflags", "+faststart", "-map_metadata", "0"]

        case .gif:
            // The gif encoder comes from the extension; -loop is a muxer option.
            args += ["-an"]

        case .webp:
            // compression_level is libwebp's "method": 6 is the most effort it will spend
            // looking for a smaller file, which is the whole point of choosing WebP.
            args += ["-c:v", "libwebp", "-compression_level", "6",
                     "-quality", String(settings.webpQuality), "-an"]
            if settings.webpLossless {
                // Lossless works in RGB; handing it yuv420p would throw away the colour
                // detail first and then store the result exactly.
                args += ["-lossless", "1", "-pix_fmt", "bgra"]
            } else {
                args += ["-lossless", "0", "-pix_fmt", "yuv420p"]
            }
        }

        if let loop = settings.format.loopValue(forever: settings.loopForever) {
            args += ["-loop", loop]
        }

        args += ["-progress", "pipe:1", "-nostats"]
        args.append(output.path)
        return args
    }

    /// GIF first pass: study the whole clip and write one palette for it.
    ///
    /// Doing this in a single graph (`split` → `palettegen` → `paletteuse`) also works, but
    /// palettegen has to see every frame before paletteuse can emit one, so ffmpeg buffers
    /// the entire clip in memory. Two passes cost a decode and stay flat.
    static func paletteArguments(
        input: URL,
        palette: URL,
        info: MediaInfo,
        crop: CGRect,
        regions: [CGRect] = [],
        zoomShots: [ZoomShot] = [],
        settings: ExportSettings,
        subtitles: URL? = nil
    ) -> [String] {
        let cropRect = crop.evenClamped(in: info.fullFrame)
        // Both GIF passes must see exactly the same frames, captions included, or the
        // palette is built for a picture the encode never renders.
        var tail = videoTail(info: info, crop: cropRect, zoomShots: zoomShots,
                             settings: settings, subtitles: subtitles)
        // stats_mode=diff weights the palette towards whatever moves — the part anyone
        // actually looks at. A still background can afford to band a little.
        tail.append("palettegen=max_colors=\(settings.gifColors.rawValue):stats_mode=diff")

        var args = ["-hide_banner", "-nostdin", "-y", "-i", input.path]
        args += mapped(
            filterGraph(
                head: videoHead(info: info, settings: settings),
                regions: regions.map { $0.evenClamped(in: info.fullFrame) },
                style: settings.blurStyle,
                strength: settings.blurStrength,
                tail: tail
            ),
            audio: false
        )
        args += ["-an", "-progress", "pipe:1", "-nostats"]
        args.append(palette.path)
        return args
    }

    /// Whether this export needs a loudness analysis pass before the encode.
    static func needsLoudnessPass(info: MediaInfo, settings: ExportSettings) -> Bool {
        settings.format == .mp4 && settings.audio == .normalised && info.hasAudio
    }

    /// Loudness first pass: decode the audio, measure it, print the numbers, write nothing.
    ///
    /// One pass on its own would also "work", but `loudnorm` without measurements is a
    /// dynamic-range compressor — it moves quiet and loud parts relative to each other.
    /// Measuring first and feeding the numbers back makes the second pass a single gain
    /// change, which is what "normalise" ought to mean.
    static func loudnessArguments(input: URL) -> [String] {
        [
            "-hide_banner", "-nostdin", "-y", "-i", input.path,
            "-map", "0:a:0",
            "-af", "loudnorm=\(Loudness.filterTargets):print_format=json",
            "-vn", "-f", "null",
            "-progress", "pipe:1", "-nostats",
            "-",
        ]
    }

    /// Pulls the analysis pass's numbers out of ffmpeg's stderr.
    ///
    /// `loudnorm` prints a JSON object after everything else it has to say, so the last
    /// braces in the log are the measurement. Digitally silent audio measures as `-inf`,
    /// which ffmpeg will not accept back; that returns nil and the encode falls through to
    /// the unmeasured filter, which is harmless on silence.
    static func parseLoudness(_ stderr: String) -> LoudnessMeasurement? {
        guard let open = stderr.lastIndex(of: "{"),
              let close = stderr.lastIndex(of: "}"),
              open < close,
              let data = String(stderr[open...close]).data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any]
        else { return nil }

        func measured(_ key: String) -> String? {
            let text: String
            if let s = root[key] as? String { text = s }
            else if let d = root[key] as? Double { text = String(d) }
            else { return nil }
            // Reject -inf/nan rather than handing ffmpeg something it will reject louder.
            guard let value = Double(text), value.isFinite else { return nil }
            return text
        }

        guard let i = measured("input_i"), let tp = measured("input_tp"),
              let lra = measured("input_lra"), let thresh = measured("input_thresh"),
              let offset = measured("target_offset")
        else { return nil }

        return LoudnessMeasurement(inputI: i, inputTP: tp, inputLRA: lra,
                                   inputThresh: thresh, targetOffset: offset)
    }

    /// Where the GIF palette for `output` is staged. Derived from the output name rather
    /// than random, so the command shown in the sidebar is exactly the one that runs.
    static func paletteURL(for output: URL) -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("yamvideo-palette-" + output.deletingPathExtension().lastPathComponent)
            .appendingPathExtension("png")
    }

    /// Every ffmpeg invocation an export will make, in order. GIF needs two; everything
    /// else is a single command.
    static func exportCommands(
        input: URL,
        output: URL,
        info: MediaInfo,
        crop: CGRect,
        regions: [CGRect] = [],
        zoomShots: [ZoomShot] = [],
        settings: ExportSettings,
        subtitles: URL? = nil
    ) -> [[String]] {
        let palette = settings.format == .gif ? paletteURL(for: output) : nil
        var commands: [[String]] = []
        if needsLoudnessPass(info: info, settings: settings) {
            commands.append(loudnessArguments(input: input))
        }
        if let palette {
            commands.append(paletteArguments(input: input, palette: palette, info: info,
                                             crop: crop, regions: regions,
                                             zoomShots: zoomShots, settings: settings,
                                             subtitles: subtitles))
        }
        commands.append(exportArguments(input: input, output: output, info: info, crop: crop,
                                        regions: regions, zoomShots: zoomShots,
                                        settings: settings, subtitles: subtitles,
                                        palette: palette))
        return commands
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
        zoomShots: [ZoomShot] = [],
        settings: ExportSettings,
        subtitles: URL? = nil,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws {
        guard let ffmpeg = ffmpegPath else {
            throw FFmpegError(message: "ffmpeg was not found.")
        }
        // Fail with something actionable instead of ffmpeg's "Unknown encoder 'libwebp'"
        // four passes into the error log.
        if settings.format == .webp, await !supportsWebP() {
            throw FFmpegError(message: "This copy of ffmpeg was built without libwebp, so it "
                + "cannot write WebP. Homebrew's plain ffmpeg is a slim build — install "
                + "ffmpeg-full (brew install ffmpeg-full) and relaunch, or export a GIF instead.")
        }
        // Silently skipping the tone map would write a file that is wrong in a way the
        // user cannot see until they open it somewhere else, so refuse instead.
        if info.isHDR, settings.toneMapHDR, await !supportsToneMapping() {
            throw FFmpegError(message: "This clip is \(info.hdrLabel ?? "HDR") and this copy of "
                + "ffmpeg has no zscale filter, so it cannot tone-map to SDR. Install "
                + "ffmpeg-full (brew install ffmpeg-full) and relaunch, or turn off "
                + "Convert HDR to SDR to export the source colours unchanged.")
        }
        // Fail here, before the first pass, rather than letting ffmpeg complain about a
        // filename halfway through an encode.
        if let subtitles {
            if await !supportsSubtitles() {
                throw FFmpegError(message: "This copy of ffmpeg was built without libass, so it "
                    + "cannot burn subtitles in. Install ffmpeg-full (brew install ffmpeg-full) "
                    + "and relaunch, or clear the subtitle file in the Subtitles section.")
            }
            try stageSubtitles(subtitles)
        }

        defer {
            if settings.format == .gif {
                try? FileManager.default.removeItem(at: paletteURL(for: output))
            }
        }

        let commands = exportCommands(input: input, output: output, info: info, crop: crop,
                                      regions: regions, zoomShots: zoomShots,
                                      settings: settings, subtitles: subtitles)
        let measuring = needsLoudnessPass(info: info, settings: settings)

        // A preparatory pass only decodes, so it finishes well before the encode that
        // follows. The loudness pass reads audio alone and is quicker still. One boundary
        // per pass, whatever the combination turns out to be.
        var bounds: [Double] = [0]
        for index in 0..<max(0, commands.count - 1) {
            let share = (measuring && index == 0) ? 0.1 : 0.3
            bounds.append(min(0.9, bounds[bounds.count - 1] + share))
        }
        bounds.append(1)

        var measurement: LoudnessMeasurement?

        for (index, command) in commands.enumerated() {
            let isEncode = index == commands.count - 1
            var args = command
            // The encode's loudnorm cannot be written until the pass above has measured,
            // so it is rebuilt here rather than reusing the placeholder from the list.
            if isEncode, measuring {
                args = exportArguments(
                    input: input, output: output, info: info, crop: crop,
                    regions: regions, zoomShots: zoomShots, settings: settings,
                    subtitles: subtitles,
                    palette: settings.format == .gif ? paletteURL(for: output) : nil,
                    loudness: measurement
                )
            }

            // Each command writes its last argument — except the measurement pass, whose
            // "-" is the null muxer and must not be treated as a file to clean up.
            let last = args[args.count - 1]
            let target = last == "-" ? nil : URL(fileURLWithPath: last)
            let result = try await runPass(ffmpeg, args, writing: target,
                                           duration: info.duration,
                                           from: bounds[index], to: bounds[index + 1],
                                           onProgress: onProgress)
            if measuring, index == 0 {
                measurement = parseLoudness(result.stderrText)
            }
        }
        onProgress(1)
    }

    /// Runs one ffmpeg pass, reporting its progress into the `from...to` slice of the whole
    /// job and cleaning up after itself if it fails or is cancelled.
    @discardableResult
    private static func runPass(
        _ ffmpeg: String,
        _ args: [String],
        writing target: URL?,
        duration: Double,
        from: Double,
        to: Double,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> ShellResult {
        let span = to - from

        let result = try await Shell.run(ffmpeg, args) { line in
            guard duration > 0 else { return }
            let parts = line.split(separator: "=", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard parts.count == 2 else { return }
            if parts[0] == "out_time_us" || parts[0] == "out_time_ms" {
                // Both keys report microseconds in current ffmpeg builds.
                guard let micros = Double(parts[1]), micros >= 0 else { return }
                let fraction = min(1, micros / 1_000_000 / duration)
                onProgress(min(0.999, from + fraction * span))
            }
        }

        if Task.isCancelled {
            if let target { try? FileManager.default.removeItem(at: target) }
            throw CancellationError()
        }

        guard result.status == 0 else {
            if let target { try? FileManager.default.removeItem(at: target) }
            let stderr = result.stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
            let tail = stderr.split(separator: "\n").suffix(4).joined(separator: "\n")
            throw FFmpegError(message: tail.isEmpty ? "ffmpeg exited with code \(result.status)." : tail)
        }
        return result
    }

    /// A non-colliding path for the given source file, in the chosen output format.
    static func outputURL(for input: URL, settings: ExportSettings) -> URL {
        let folder = settings.outputFolder ?? input.deletingLastPathComponent()
        let stem = input.deletingPathExtension().lastPathComponent
        let suffix = settings.suffix
        let ext = settings.format.fileExtension
        var candidate = folder.appendingPathComponent(stem + suffix).appendingPathExtension(ext)

        if candidate.path.compare(input.path, options: .caseInsensitive) != .orderedSame,
           !FileManager.default.fileExists(atPath: candidate.path) {
            return candidate
        }
        var counter = 2
        repeat {
            candidate = folder
                .appendingPathComponent("\(stem)\(suffix)-\(counter)")
                .appendingPathExtension(ext)
            counter += 1
        } while FileManager.default.fileExists(atPath: candidate.path) && counter < 1000
        return candidate
    }
}
