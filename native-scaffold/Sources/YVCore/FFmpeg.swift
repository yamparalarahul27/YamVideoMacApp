import Foundation

/// ffmpeg has exactly two jobs in this app (PLAN.md §2.5): GIF encoding and
/// lossless concat. It is resolved from disk, never bundled.
public enum FFmpeg {

    public static func locate() -> URL? {
        let candidates = [
            "/opt/homebrew/bin/ffmpeg",
            "/usr/local/bin/ffmpeg",
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        // PATH lookup, for non-standard installs.
        if let pathVar = ProcessInfo.processInfo.environment["PATH"] {
            for dir in pathVar.split(separator: ":") {
                let path = "\(dir)/ffmpeg"
                if FileManager.default.isExecutableFile(atPath: path) {
                    return URL(fileURLWithPath: path)
                }
            }
        }
        return nil
    }

    public static let installHint = "brew install ffmpeg"

    // MARK: - GIF (PLAN.md §7.4)

    /// Single-pass palette GIF: palettegen learns the best 256 colours from
    /// the actual footage, paletteuse applies them. stats_mode=diff and
    /// diff_mode=rectangle both favour screencasts.
    public static func gifArgs(
        input: URL,
        output: URL,
        startSeconds: Double? = nil,
        endSeconds: Double? = nil,
        settings: GifSettings
    ) -> [String] {
        var args = ["-y", "-hide_banner"]
        if let start = startSeconds { args += ["-ss", String(format: "%.3f", start)] }
        if let end = endSeconds { args += ["-to", String(format: "%.3f", end)] }
        args += ["-i", input.path]

        let ditherExpr = settings.dither == .none
            ? "dither=none"
            : settings.dither == .bayer
                ? "dither=bayer:bayer_scale=5"
                : "dither=sierra2_4a"

        let filter = "fps=\(settings.fps),scale=\(settings.width):-1:flags=lanczos,"
            + "split[a][b];[a]palettegen=stats_mode=diff[p];"
            + "[b][p]paletteuse=\(ditherExpr):diff_mode=rectangle"

        args += ["-vf", filter, "-loop", settings.loop ? "0" : "-1", output.path]
        return args
    }

    // MARK: - Lossless concat (PLAN.md §7.3, used from Phase 3)

    public static func concatArgs(listFile: URL, output: URL) -> [String] {
        ["-y", "-hide_banner", "-f", "concat", "-safe", "0",
         "-i", listFile.path, "-c", "copy", "-movflags", "+faststart", output.path]
    }

    // MARK: - Running

    public enum RunError: LocalizedError {
        case notInstalled
        case failed(exitCode: Int32, stderrTail: String)

        public var errorDescription: String? {
            switch self {
            case .notInstalled:
                return "ffmpeg is not installed. Run: \(FFmpeg.installHint)"
            case .failed(let code, let tail):
                return "ffmpeg exited with \(code): \(tail)"
            }
        }
    }

    public static func run(args: [String]) async throws {
        guard let binary = locate() else { throw RunError.notInstalled }

        let process = Process()
        process.executableURL = binary
        process.arguments = args
        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        process.standardOutput = FileHandle.nullDevice

        // Drain stderr concurrently so a chatty encode can't fill the pipe and
        // deadlock the exit wait.
        let stderrTask = Task.detached(priority: .utility) {
            stderrPipe.fileHandleForReading.readDataToEndOfFile()
        }

        try process.run()

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .utility).async {
                process.waitUntilExit()
                continuation.resume()
            }
        }
        let stderrData = await stderrTask.value

        if process.terminationStatus != 0 {
            let text = String(data: stderrData, encoding: .utf8) ?? ""
            let tail = text.split(separator: "\n").suffix(4).joined(separator: " · ")
            throw RunError.failed(exitCode: process.terminationStatus, stderrTail: tail)
        }
    }
}
