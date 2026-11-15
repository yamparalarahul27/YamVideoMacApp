import Foundation
import Combine

// Downloads are a local app library, separate from a video's undo/document history.
enum DownloadPhase: String, Codable { case queued, inspecting, downloading, processing, completed, failed, cancelled
    var isActive: Bool { [.inspecting, .downloading, .processing].contains(self) }
    var label: String { rawValue.capitalized }
}
enum DownloadKind: String, Codable, CaseIterable { case video, audio
    var label: String { self == .video ? "Video" : "Audio only (M4A)" }
}
enum DownloadQuality: String, Codable, CaseIterable { case best, fullHD, hd
    var label: String { switch self { case .best: return "Best available"; case .fullHD: return "Up to 1080p"; case .hd: return "Up to 720p" } }
    var height: Int? { self == .fullHD ? 1080 : self == .hd ? 720 : nil }
}
enum DownloadBrowser: String, Codable, CaseIterable { case none, safari, chrome, firefox
    var label: String { self == .none ? "No browser login" : rawValue.capitalized }
}
struct DownloadEntry: Identifiable, Codable {
    var id = UUID()
    var source: String
    var title: String
    var created = Date()
    var phase = DownloadPhase.queued
    var progress: Double?
    var detail = "Waiting"
    var error: String?
    var files: [String] = []
    var folder: String
    var kind: DownloadKind
    var quality: DownloadQuality
    var browser: DownloadBrowser
}
struct DownloadInspection: Equatable {
    var title: String
    var duration: Double?
    var uploader: String?
    var thumbnail: URL?
    static func parse(_ data: Data) throws -> Self {
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let first = (root["entries"] as? [[String: Any]])?.first ?? root
        return Self(title: root["title"] as? String ?? first["title"] as? String ?? "Media",
                    duration: first["duration"] as? Double,
                    uploader: first["uploader"] as? String,
                    thumbnail: (first["thumbnail"] as? String).flatMap(URL.init(string:)))
    }
}
enum DownloadEngine {
    static func validatedURL(_ text: String) throws -> URL {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let c = URLComponents(string: trimmed), let scheme = c.scheme?.lowercased(),
              ["http", "https"].contains(scheme), let host = c.host, !host.isEmpty,
              c.user == nil, c.password == nil, let url = c.url else {
            throw DownloadFailure("Paste a complete http or https video link.")
        }
        return url
    }
    static func tool(_ name: String) -> String? {
        let paths = ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin", "/usr/bin", "/opt/homebrew/opt/ffmpeg-full/bin", "/usr/local/opt/ffmpeg-full/bin"]
        return paths.map { ($0 as NSString).appendingPathComponent(name) }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
    static var missingTools: [String] { ["yt-dlp", "ffmpeg", "ffprobe", "deno"].filter { tool($0) == nil } }
    static func arguments(url: URL, folder: URL?, kind: DownloadKind, quality: DownloadQuality, browser: DownloadBrowser, inspect: Bool) -> [String] {
        var args = ["--ignore-config", "--no-playlist", "--no-color", "--socket-timeout", "30", "--retries", "3", "--fragment-retries", "3"]
        if let deno = tool("deno") { args += ["--js-runtimes", "deno:" + deno] }
        if let ffmpeg = tool("ffmpeg") { args += ["--ffmpeg-location", (ffmpeg as NSString).deletingLastPathComponent] }
        if browser != .none { args += ["--cookies-from-browser", browser.rawValue] }
        if inspect { args += ["--dump-single-json", "--skip-download"] }
        else {
            if kind == .audio { args += ["-x", "--audio-format", "m4a", "--audio-quality", "0"] }
            else {
                if let h = quality.height { args += ["-f", "bv*[height<=?\(h)]+ba/b[height<=?\(h)]"] }
                args += ["-S", "res,fps,vcodec:h264,acodec:aac", "--merge-output-format", "mp4/mkv"]
            }
            args += ["--newline", "--progress", "--progress-delta", "0.5",
                     "--progress-template", "download:yv-progress:%(progress)j",
                     "--progress-template", "postprocess:yv-post:%(progress.status)s",
                     "--print", "after_move:yv-file:%(filepath)j", "--no-simulate",
                     "--windows-filenames", "--trim-filenames", "180",
                     "--paths", folder?.path ?? "", "--output", "%(title).140B [%(id)s].%(ext)s"]
        }
        return args + ["--", url.absoluteString]
    }
    static func progress(_ line: String) -> (Double?, String)? {
        guard line.hasPrefix("yv-progress:"), let data = line.dropFirst(12).data(using: .utf8),
              let p = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let done = (p["downloaded_bytes"] as? NSNumber)?.doubleValue ?? 0
        let total = (p["total_bytes"] as? NSNumber)?.doubleValue ?? (p["total_bytes_estimate"] as? NSNumber)?.doubleValue ?? 0
        let fraction = total > 0 ? min(1, max(0, done / total)) : nil
        let speed = (p["speed"] as? NSNumber)?.doubleValue
        let text = speed.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) + "/s" } ?? "Downloading"
        return (fraction, text)
    }
    static func resultFile(_ line: String) -> String? {
        guard line.hasPrefix("yv-file:"), let data = line.dropFirst(8).data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(String.self, from: data)
    }
    static func friendlyError(_ raw: String) -> String {
        let lines = raw.components(separatedBy: .newlines).filter { $0.contains("ERROR:") }
        let error = (lines.last ?? raw).trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = error.lowercased()
        if lower.contains("sign in") || lower.contains("login") || lower.contains("cookies") {
            return "This link needs a browser session. Choose the browser where you can view it, then retry. " + String(error.suffix(350))
        }
        if lower.contains("unsupported url") { return "This link is not supported. Try the original video's page or a direct media file link." }
        if lower.contains("403") || lower.contains("signature") || lower.contains("challenge") {
            return "The site refused this download. Check for a yt-dlp update; some links also need a browser session. " + String(error.suffix(350))
        }
        return error.isEmpty ? "The download did not finish. Check the link and your connection, then retry." : String(error.suffix(650))
    }
}
struct DownloadFailure: LocalizedError { var message: String; init(_ message: String) { self.message = message }; var errorDescription: String? { message } }

@MainActor final class DownloadStore: ObservableObject {
    static let shared = DownloadStore()
    @Published private(set) var entries: [DownloadEntry] = []
    @Published var destination: URL
    @Published private(set) var inspection: DownloadInspection?
    @Published private(set) var isInspecting = false
    @Published var message: String?
    private var active: UUID?
    private var worker: Task<Void, Never>?
    private var inspector: Task<Void, Never>?
    private var inspectionID = UUID()
    private let historyURL: URL
    private let settingsURL: URL

    init(dataDirectory: URL? = nil, outputDirectory: URL? = nil) {
        let fm = FileManager.default
        let root = dataDirectory ?? fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("YamVideo/Downloads", isDirectory: true)
        historyURL = root.appendingPathComponent("history.json")
        settingsURL = root.appendingPathComponent("destination.txt")
        let fallback = outputDirectory ?? fm.urls(for: .downloadsDirectory, in: .userDomainMask)[0].appendingPathComponent("YamVideo", isDirectory: true)
        if let text = try? String(contentsOf: settingsURL, encoding: .utf8), !text.isEmpty { destination = URL(fileURLWithPath: text, isDirectory: true) } else { destination = fallback }
        if let data = try? Data(contentsOf: historyURL), let saved = try? JSONDecoder().decode([DownloadEntry].self, from: data) {
            entries = saved.map { item in
                var item = item
                if item.phase.isActive || item.phase == .queued { item.phase = .cancelled; item.detail = "Interrupted when YamVideo closed. Retry to continue." }
                return item
            }
        }
    }
    func setDestination(_ url: URL) {
        destination = url
        do { try FileManager.default.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true); try url.path.write(to: settingsURL, atomically: true, encoding: .utf8) }
        catch { message = "Could not remember this folder: \(error.localizedDescription)" }
    }
    func clearInspection() { inspector?.cancel(); inspectionID = UUID(); inspection = nil; isInspecting = false; message = nil }
    func inspect(_ text: String, browser: DownloadBrowser) {
        inspector?.cancel(); let request = UUID(); inspectionID = request; inspection = nil; message = nil
        guard let url = try? DownloadEngine.validatedURL(text) else { isInspecting = false; message = "Paste a complete http or https video link."; return }
        guard let tool = DownloadEngine.tool("yt-dlp") else { isInspecting = false; message = "Install yt-dlp to inspect video links."; return }
        isInspecting = true
        inspector = Task { [weak self] in
            do {
                let result = try await Shell.run(tool, DownloadEngine.arguments(url: url, folder: nil, kind: .video, quality: .best, browser: browser, inspect: true))
                try Task.checkCancellation()
                guard let self, self.inspectionID == request else { return }
                guard result.status == 0 else { throw DownloadFailure(DownloadEngine.friendlyError(result.stderrText)) }
                self.inspection = try DownloadInspection.parse(result.stdout); self.isInspecting = false
            } catch {
                guard let self, self.inspectionID == request else { return }
                self.isInspecting = false
                if !(error is CancellationError) { self.message = error.localizedDescription }
            }
        }
    }
    func enqueue(_ text: String, kind: DownloadKind, quality: DownloadQuality, browser: DownloadBrowser) {
        do {
            let url = try DownloadEngine.validatedURL(text)
            guard DownloadEngine.missingTools.isEmpty else { throw DownloadFailure("Install the missing download tools before downloading.") }
            let title = inspection?.title ?? url.host ?? "Video"
            entries.insert(DownloadEntry(source: url.absoluteString, title: title, folder: destination.path, kind: kind, quality: quality, browser: browser), at: 0)
            inspection = nil; message = nil; save(); startNext()
        } catch { message = error.localizedDescription }
    }
    func cancel(_ id: UUID) {
        guard let i = entries.firstIndex(where: { $0.id == id }), entries[i].phase != .completed else { return }
        entries[i].phase = .cancelled; entries[i].detail = "Cancelled"; save()
        if active == id { worker?.cancel() }
    }
    func retry(_ id: UUID) {
        guard let i = entries.firstIndex(where: { $0.id == id }), [.failed, .cancelled].contains(entries[i].phase) else { return }
        entries[i].phase = .queued; entries[i].error = nil; entries[i].progress = nil; entries[i].detail = "Waiting"; save(); startNext()
    }
    func remove(_ id: UUID) {
        guard active != id else { return }
        entries.removeAll { $0.id == id }; save()
    }
    private func update(_ id: UUID, _ body: (inout DownloadEntry) -> Void) {
        guard let i = entries.firstIndex(where: { $0.id == id }), entries[i].phase != .cancelled else { return }
        body(&entries[i])
    }
    private func save() {
        do { try FileManager.default.createDirectory(at: historyURL.deletingLastPathComponent(), withIntermediateDirectories: true); try JSONEncoder().encode(entries).write(to: historyURL, options: .atomic) }
        catch { message = "Download history could not be saved: \(error.localizedDescription)" }
    }
    private func startNext() {
        guard worker == nil, let job = entries.last(where: { $0.phase == .queued }) else { return }
        active = job.id
        worker = Task { [weak self] in
            guard let self else { return }
            defer { self.active = nil; self.worker = nil; self.save(); self.startNext() }
            do {
                let url = try DownloadEngine.validatedURL(job.source)
                let work = URL(fileURLWithPath: job.folder, isDirectory: true).appendingPathComponent(".partial-\(job.id.uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: work) }
                self.update(job.id) { $0.phase = .downloading; $0.detail = "Connecting…" }
                guard let tool = DownloadEngine.tool("yt-dlp") else { throw DownloadFailure("yt-dlp is missing.") }
                let result = try await Shell.run(tool, DownloadEngine.arguments(url: url, folder: work, kind: job.kind, quality: job.quality, browser: job.browser, inspect: false), onStdoutLine: { [weak self] line in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        if let (progress, detail) = DownloadEngine.progress(line) { self.update(job.id) { $0.phase = .downloading; $0.progress = progress; $0.detail = detail } }
                        if line.hasPrefix("yv-post:") { self.update(job.id) { $0.phase = .processing; $0.detail = "Preparing file…" } }
                    }
                })
                try Task.checkCancellation()
                guard result.status == 0 else { throw DownloadFailure(DownloadEngine.friendlyError(result.stderrText)) }
                // stdout is streamed, so locate only this job's isolated staging directory.
                let parts = try FileManager.default.contentsOfDirectory(at: work, includingPropertiesForKeys: nil).filter { !["part", "ytdl", "temp"].contains($0.pathExtension) && !$0.lastPathComponent.hasPrefix(".") }
                guard !parts.isEmpty else { throw DownloadFailure("No media file was produced.") }
                var files: [String] = []
                for source in parts {
                    let destination = DownloadStore.availableDestination(for: source.lastPathComponent, in: URL(fileURLWithPath: job.folder, isDirectory: true))
                    try FileManager.default.moveItem(at: source, to: destination); files.append(destination.path)
                }
                self.update(job.id) { $0.phase = .completed; $0.progress = 1; $0.files = files; $0.detail = files.count == 1 ? "Ready" : "\(files.count) files ready"; if job.title == url.host, let first = files.first { $0.title = URL(fileURLWithPath: first).deletingPathExtension().lastPathComponent } }
            } catch {
                if error is CancellationError || Task.isCancelled { self.update(job.id) { $0.phase = .cancelled; $0.detail = "Cancelled" } }
                else { self.update(job.id) { $0.phase = .failed; $0.error = error.localizedDescription; $0.detail = "Download failed" } }
            }
        }
    }
    static func availableDestination(for name: String, in folder: URL) -> URL {
        let file = URL(fileURLWithPath: name); let stem = file.deletingPathExtension().lastPathComponent; let ext = file.pathExtension
        var output = folder.appendingPathComponent(name); var count = 2
        while FileManager.default.fileExists(atPath: output.path) { output = folder.appendingPathComponent("\(stem) (\(count))" + (ext.isEmpty ? "" : ".\(ext)")); count += 1 }
        return output
    }
}
