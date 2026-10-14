import Foundation
import SwiftUI
import YVCore

/// One file in the Export queue.
struct ExportItem: Identifiable {
    enum Status: Equatable {
        case probing
        case ready
        case working(Double)           // 0–1
        case done(URL, Int64, remux: Bool)
        case failed(String)
    }

    let id = UUID()
    let url: URL
    var info: MediaInfo?
    var status: Status = .probing
    var canRemux = false

    var name: String { url.lastPathComponent }
}

@MainActor
final class ExportModel: ObservableObject {
    @Published var items: [ExportItem] = []
    @Published var preset: ExportPreset = .webSafeH264
    /// When the source is already MP4-compatible, remux (instant, lossless)
    /// instead of re-encoding. Off forces a transcode at the chosen preset.
    @Published var preferRemux = true

    // GIF
    @Published var gif = GifSettings()
    @Published var gifStartText = ""
    @Published var gifEndText = ""
    @Published private(set) var ffmpegPath: String?

    private var converting = false

    init() {
        refreshFFmpeg()
    }

    func refreshFFmpeg() {
        ffmpegPath = FFmpeg.locate()?.path
    }

    // MARK: - Adding files

    func add(urls: [URL]) {
        for url in urls {
            guard !items.contains(where: { $0.url == url }) else { continue }
            var item = ExportItem(url: url)
            item.status = .probing
            items.append(item)
            let id = item.id
            Task { await self.probe(id: id, url: url) }
        }
    }

    private func probe(id: UUID, url: URL) async {
        do {
            let info = try await MediaInfo.probe(url)
            let canRemux = await Exporter.canRemuxToMP4(url)
            update(id) {
                $0.info = info
                $0.canRemux = canRemux
                $0.status = .ready
            }
        } catch {
            update(id) { $0.status = .failed(error.localizedDescription) }
        }
    }

    // MARK: - MP4

    func convertAll() {
        guard !converting else { return }
        converting = true
        let ids = items.filter { $0.status == .ready }.map(\.id)
        Task {
            // Serial on purpose: one VideoToolbox encode at a time is the
            // fastest wall-clock path anyway, and progress stays legible.
            for id in ids { await self.convertOne(id: id) }
            self.converting = false
        }
    }

    func convert(id: UUID) {
        Task { await self.convertOne(id: id) }
    }

    private func convertOne(id: UUID) async {
        guard let item = items.first(where: { $0.id == id }) else { return }
        let out = Exporter.defaultOutputURL(for: item.url)
        update(id) { $0.status = .working(0) }
        do {
            let result: ExportResult
            if preferRemux {
                result = try await Exporter.convertToMP4(
                    item.url, outputURL: out, preset: preset,
                    progress: { [weak self] p in
                        Task { @MainActor in self?.update(id) { $0.status = .working(p) } }
                    })
            } else {
                result = try await Exporter.transcodeToMP4(
                    item.url, outputURL: out, preset: preset,
                    progress: { [weak self] p in
                        Task { @MainActor in self?.update(id) { $0.status = .working(p) } }
                    })
            }
            update(id) { $0.status = .done(result.outputURL, result.outputBytes, remux: result.wasRemux) }
        } catch {
            update(id) { $0.status = .failed(error.localizedDescription) }
        }
    }

    // MARK: - GIF

    var gifRange: (start: Double?, end: Double?) {
        (Self.parseTime(gifStartText), Self.parseTime(gifEndText))
    }

    /// Accepts "90", "1:30", "1:30.5".
    static func parseTime(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let parts = trimmed.split(separator: ":").map(String.init)
        var seconds = 0.0
        for part in parts {
            guard let value = Double(part) else { return nil }
            seconds = seconds * 60 + value
        }
        return seconds
    }

    /// Rough size guess shown before export (PLAN.md §2.6): GIF bytes scale
    /// close to linearly with pixels × frames for screencasts.
    func gifEstimate(for item: ExportItem) -> String? {
        guard let info = item.info, info.width > 0 else { return nil }
        let (start, end) = gifRange
        let duration = min(info.duration, (end ?? info.duration)) - (start ?? 0)
        guard duration > 0 else { return nil }
        let height = Double(gif.width) * Double(info.height) / Double(info.width)
        let frames = duration * Double(gif.fps)
        // ~0.10 bytes/pixel/frame is a screencast-ish midpoint; ±2× in practice.
        let bytes = Int64(Double(gif.width) * height * frames * 0.10)
        return MediaInfo.formatBytes(bytes)
    }

    func exportGif(id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        let out = Exporter.defaultOutputURL(for: item.url, ext: "gif")
        let (start, end) = gifRange
        let args = FFmpeg.gifArgs(input: item.url, output: out,
                                  startSeconds: start, endSeconds: end,
                                  settings: gif)
        update(id) { $0.status = .working(0) }
        Task {
            do {
                try await FFmpeg.run(args: args)
                let bytes = (try? FileManager.default
                    .attributesOfItem(atPath: out.path)[.size] as? Int64) ?? 0
                self.update(id) { $0.status = .done(out, bytes, remux: false) }
            } catch {
                self.update(id) { $0.status = .failed(error.localizedDescription) }
            }
        }
    }

    // MARK: -

    func remove(id: UUID) {
        items.removeAll { $0.id == id }
    }

    func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func update(_ id: UUID, _ transform: (inout ExportItem) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        transform(&items[index])
    }
}
