import CryptoKit
import Foundation

// MARK: - whisper.cpp

/// whisper.cpp (MIT) transcribes on this Mac: `whisper-cli` from Homebrew's whisper-cpp
/// formula, with a model the owner downloads once from Auto Edit. The audio never leaves
/// the Mac. Word times come from whisper's DTW alignment (`-dtw`, which needs flash
/// attention off, `-nfa`).
enum Whisper {
    static let missingMessage = "Transcribing needs whisper.cpp. Install it with Homebrew (brew install whisper-cpp), then try again."

    enum Status: Equatable, Sendable {
        case ready
        case needsWhisper
        case needsModel(TranscriptModel)
    }

    /// `whisper-cli`, found where ffmpeg is looked for (Homebrew, MacPorts, /usr/local).
    static var cliPath: String? {
        if let override = ProcessInfo.processInfo.environment["YAMVIDEO_WHISPER_CLI"], !override.isEmpty {
            return FileManager.default.isExecutableFile(atPath: override) ? override : nil
        }
        return FFmpeg.locate("whisper-cli")
    }

    static var modelsFolder: URL {
        if let override = ProcessInfo.processInfo.environment["YAMVIDEO_WHISPER_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("YamVideo/Whisper", isDirectory: true)
    }

    static func modelFile(_ model: TranscriptModel) -> URL { modelsFolder.appendingPathComponent(model.fileName) }

    /// On this Mac at its published size. The checksum is checked once, when it arrives.
    static func hasModel(_ model: TranscriptModel) -> Bool {
        let size = (try? FileManager.default.attributesOfItem(atPath: modelFile(model).path)[.size] as? NSNumber)?.int64Value
        return size == model.bytes
    }

    static func status(_ model: TranscriptModel) -> Status {
        guard cliPath != nil else { return .needsWhisper }
        return hasModel(model) ? .ready : .needsModel(model)
    }

    static func needsModelMessage(_ model: TranscriptModel) -> String {
        "The \(model.label) model (\(model.sizeLabel)) is not on this Mac yet. Only the owner can download it, in Auto Edit."
    }

    // MARK: Downloading a model

    /// Downloads a model from whisper.cpp's page on Hugging Face into the app's folder.
    /// Only ever called on the owner's click. The file is checked against its published
    /// size and SHA-256 before it replaces anything; a failed download changes nothing.
    static func download(_ model: TranscriptModel, progress: @escaping @Sendable (Double) -> Void) async throws {
        let manager = FileManager.default
        try manager.createDirectory(at: modelsFolder, withIntermediateDirectories: true)
        let staging = modelsFolder.appendingPathComponent(".download-\(UUID().uuidString)")
        defer { try? manager.removeItem(at: staging) }
        let delegate = ModelDownload(destination: staging, expected: model.bytes, progress: progress)
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let task = session.downloadTask(with: model.downloadURL)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                delegate.continuation = continuation
                task.resume()
            }
        } onCancel: { task.cancel() }
        try Task.checkCancellation()
        let size = (try manager.attributesOfItem(atPath: staging.path)[.size] as? NSNumber)?.int64Value
        guard size == model.bytes, try sha256(of: staging) == model.sha256 else {
            throw FFmpegError(message: "The \(model.label) model did not download intact (its size or checksum is wrong). Try again.")
        }
        try? manager.removeItem(at: modelFile(model))
        try manager.moveItem(at: staging, to: modelFile(model))
    }

    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 8 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Transcribing

    /// Transcribes a recording's first audio track, word by word, in source seconds.
    /// `progress` goes from 0 to 1.
    static func transcribe(_ source: URL, duration: Double, model: TranscriptModel, language: String,
                           progress: @escaping @Sendable (Double) -> Void) async throws -> Transcript {
        guard let cli = cliPath else { throw FFmpegError(message: missingMessage) }
        guard hasModel(model) else { throw FFmpegError(message: needsModelMessage(model)) }
        guard let ffmpeg = FFmpeg.ffmpegPath else { throw FFmpegError(message: "Locate ffmpeg to read the recording's audio.") }
        let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("yamvideo-whisper-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        // whisper.cpp reads 16 kHz mono PCM.
        let audio = folder.appendingPathComponent("audio.wav")
        let extracted = try await Shell.run(ffmpeg, ["-v", "error", "-nostdin", "-y", "-i", source.path, "-map", "0:a:0", "-vn",
                                                     "-ac", "1", "-ar", "16000", "-c:a", "pcm_s16le", audio.path])
        try Task.checkCancellation()
        guard extracted.status == 0 else {
            throw FFmpegError(message: "The recording's audio could not be read: \(extracted.stderrText.suffix(300))")
        }
        progress(0.03)

        let output = folder.appendingPathComponent("transcript")
        let threads = max(1, min(8, ProcessInfo.processInfo.activeProcessorCount))
        let result = try await Shell.run(cli, ["-m", modelFile(model).path, "-f", audio.path, "-l", language,
                                               "-dtw", model.dtwPreset, "-nfa", "-ojf", "-of", output.path,
                                               "-t", String(threads), "-pp"],
                                         onStderrLine: { line in
            guard let range = line.range(of: "progress =") else { return }
            let digits = line[range.upperBound...].filter(\.isNumber)
            if let percent = Double(digits) { progress(0.03 + 0.97 * min(100, percent) / 100) }
        })
        try Task.checkCancellation()
        guard result.status == 0 else {
            let tail = result.stderrText.split(separator: "\n").suffix(3).joined(separator: "\n")
            throw FFmpegError(message: "whisper.cpp could not transcribe the recording: \(tail)")
        }
        let data = try Data(contentsOf: output.appendingPathExtension("json"))
        var transcript = try parse(data, model: model.rawValue, language: language)
        for index in transcript.words.indices {
            transcript.words[index].start = min(transcript.words[index].start, duration)
            transcript.words[index].end = min(max(transcript.words[index].end, transcript.words[index].start), duration)
        }
        return transcript
    }

    /// Reads whisper-cli's full JSON (`-ojf`): words from each segment's text, timed by the
    /// DTW time of their first token (`t_dtw`, hundredths of a second), or by whisper's
    /// own token time when DTW did not run. Non-speech marks such as [BLANK_AUDIO] or
    /// (music) are left out.
    static func parse(_ data: Data, model: String, language: String) throws -> Transcript {
        struct Offsets: Decodable { var from: Int; var to: Int }
        struct Token: Decodable {
            var text: String
            var offsets: Offsets?
            var t_dtw: Int?
        }
        struct Segment: Decodable { var offsets: Offsets; var text: String; var tokens: [Token]? }
        struct Result: Decodable { var language: String? }
        struct Output: Decodable { var result: Result?; var transcription: [Segment] }

        // Tokens can split a character's bytes, which whisper.cpp writes as they are.
        let text = String(decoding: data, as: UTF8.self)
        let output: Output
        do { output = try JSONDecoder().decode(Output.self, from: Data(text.utf8)) }
        catch { throw FFmpegError(message: "This is not whisper.cpp's full JSON output (-ojf): \(error.localizedDescription)") }

        var words: [TranscriptWord] = []
        var aside = false
        for segment in output.transcription {
            let tokens = (segment.tokens ?? []).filter { !$0.text.hasPrefix("[_") && !$0.text.hasPrefix("<|") && !$0.text.isEmpty }
            // A word starts at a token that begins with a space.
            var groups: [(text: String, time: Double)] = []
            for token in tokens {
                let time = (token.t_dtw ?? -1) >= 0 ? Double(token.t_dtw!) / 100 : Double(token.offsets?.from ?? segment.offsets.from) / 1000
                if token.text.hasPrefix(" ") || groups.isEmpty { groups.append((token.text, time)) }
                else { groups[groups.count - 1].text += token.text }
            }
            let spoken = segment.text.split(whereSeparator: \.isWhitespace).map(String.init)
            let texts = spoken.count == groups.count ? spoken : groups.map { $0.text.trimmingCharacters(in: .whitespaces) }
            let end = Double(segment.offsets.to) / 1000
            for (index, group) in groups.enumerated() {
                let word = texts[index]
                let opens = word.hasPrefix("[") || word.hasPrefix("(") || word.hasPrefix("*") || word.hasPrefix("♪")
                if opens { aside = true }
                defer { if aside, word.hasSuffix("]") || word.hasSuffix(")") || word.hasSuffix("*") || word.hasSuffix("♪") { aside = false } }
                guard !aside, !word.isEmpty, !word.allSatisfy({ $0.isPunctuation }) else { continue }
                let start = max(words.last?.start ?? 0, group.time)
                let next = index + 1 < groups.count ? groups[index + 1].time : end
                words.append(TranscriptWord(text: word, start: rounded(start), end: rounded(max(start + 0.02, next))))
            }
        }
        // A word's end is the next one's start at most.
        for index in words.indices.dropLast() where words[index].end > words[index + 1].start {
            words[index].end = max(words[index].start, words[index + 1].start)
        }
        return Transcript(model: model, language: output.result?.language ?? language, words: words)
    }

    private static func rounded(_ seconds: Double) -> Double { (seconds * 1000).rounded() / 1000 }
}

/// Reports a model download's progress and keeps the file before URLSession deletes it.
private final class ModelDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let destination: URL
    private let expected: Int64
    private let progress: @Sendable (Double) -> Void
    private var failure: Error?
    var continuation: CheckedContinuation<Void, Error>?

    init(destination: URL, expected: Int64, progress: @escaping @Sendable (Double) -> Void) {
        self.destination = destination; self.expected = expected; self.progress = progress
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        progress(min(1, Double(totalBytesWritten) / Double(max(1, expected))))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        lock.lock(); defer { lock.unlock() }
        if let response = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(response.statusCode) {
            failure = FFmpegError(message: "The model download failed (HTTP \(response.statusCode)).")
            return
        }
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
        } catch { failure = error }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        let failure = error ?? self.failure
        lock.unlock()
        if let failure {
            continuation?.resume(throwing: (failure as? URLError)?.code == .cancelled ? CancellationError() : failure)
        } else {
            continuation?.resume()
        }
    }
}
