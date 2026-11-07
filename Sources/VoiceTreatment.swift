import Foundation
import CryptoKit
import SwiftUI

/// Non-destructive controls. The rendered media is an implementation cache; the
/// project keeps its original source and these settings for re-tuning and bypass.
struct VoiceSettings: Codable, Equatable {
    var enabled = true
    var noiseReduction = 8.0
    var harshness = 3.0
    var sibilance = 0.35
    var warmth = 1.0
    var compression = 0.25
    var gain = 0.0
    var cutFadeMS = 25.0
    enum CodingKeys: String, CodingKey { case enabled, noiseReduction, harshness, sibilance, warmth, compression, gain, cutFadeMS }
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        noiseReduction = try c.decodeIfPresent(Double.self, forKey: .noiseReduction) ?? 8
        harshness = try c.decodeIfPresent(Double.self, forKey: .harshness) ?? 3
        sibilance = try c.decodeIfPresent(Double.self, forKey: .sibilance) ?? 0.35
        warmth = try c.decodeIfPresent(Double.self, forKey: .warmth) ?? 1
        compression = try c.decodeIfPresent(Double.self, forKey: .compression) ?? 0.25
        gain = try c.decodeIfPresent(Double.self, forKey: .gain) ?? 0
        cutFadeMS = try c.decodeIfPresent(Double.self, forKey: .cutFadeMS) ?? 25
    }
    func validate() throws {
        for (name, value, range) in [("noiseReduction",noiseReduction,0.0...24.0), ("harshness",harshness,0.0...8.0),
                                      ("sibilance",sibilance,0.0...1.0), ("warmth",warmth,0.0...4.0),
                                      ("compression",compression,0.0...1.0), ("gain",gain,-12.0...6.0), ("cutFadeMS",cutFadeMS,0.0...80.0)] {
            guard value.isFinite, range.contains(value) else { throw EditError.invalid("Voice \(name) must be between \(range.lowerBound) and \(range.upperBound).") }
        }
    }
    var filters: String {
        var f = ["highpass=f=70"]
        if noiseReduction > 0 {
            // afftdn has a 25 ms analysis delay. Flush its tail and remove that delay
            // before the signal rejoins the source timeline, keeping lips and cuts in sync.
            f.append("apad=pad_dur=0.025,afftdn=nr=\(noiseReduction):nf=-38:tn=1:gs=8,atrim=start=0.025,asetpts=PTS-STARTPTS")
        }
        if harshness > 0 { f.append("equalizer=f=3200:t=q:w=0.8:g=-\(harshness)") }
        if warmth > 0 { f.append("bass=g=\(warmth):f=180:t=q:w=0.7") }
        if sibilance > 0 { f.append("deesser=i=\(sibilance):m=0.5:f=0.5:s=o") }
        if compression > 0 { f.append("acompressor=threshold=0.125:ratio=\(1+compression*3):attack=15:release=180:makeup=1:knee=2.828") }
        return f.joined(separator: ",")
    }
}
struct VoiceTreatment: Codable, Equatable {
    var settings: VoiceSettings
    var source: URL
    var rendered: URL?
    var levelMatchDB: Double = 0
}

enum VoiceProcessor {
    /// Video packets are copied, never re-encoded. The same prepared audio is used by
    /// every player/export path through VideoItem.effective, avoiding DSP mismatches.
    static func prepare(source: URL, settings: VoiceSettings) async throws -> VoiceTreatment {
        try settings.validate()
        guard settings.enabled else { return VoiceTreatment(settings: settings, source: source) }
        guard let ffmpeg = FFmpeg.ffmpegPath else { throw FFmpegError(message: "FFmpeg is needed to prepare voice audio.") }
        let attrs = try FileManager.default.attributesOfItem(atPath: source.path)
        var keySettings = settings; keySettings.gain = 0; keySettings.cutFadeMS = 0
        let key = source.path + "|" + String(describing: attrs[.size]) + "|" + String(describing: attrs[.modificationDate]) + "|v2|" + String(data: try sortedData(keySettings), encoding: .utf8)!
        let hash = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("YamVideo/Voice", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // The user gain is included in the final output key, after loudness-matched A/B.
        let output = folder.appendingPathComponent(hash + "-g\(settings.gain).mov")
        let metadata = output.appendingPathExtension("json")
        if FileManager.default.fileExists(atPath: output.path), let data = try? Data(contentsOf: metadata),
           var ready = try? JSONDecoder().decode(VoiceTreatment.self, from: data) { ready.settings = settings; return ready }
        let audio = folder.appendingPathComponent(UUID().uuidString + ".wav")
        let temporary = folder.appendingPathComponent(UUID().uuidString + ".mov")
        defer { try? FileManager.default.removeItem(at: audio); try? FileManager.default.removeItem(at: temporary) }
        let original = try await FFmpeg.probe(url: source)
        try await run(ffmpeg, ["-hide_banner","-nostdin","-y","-i",source.path,"-vn","-af",settings.filters + ",apad,atrim=duration=\(original.duration)","-ar","48000","-c:a","pcm_s24le",audio.path])
        async let before = FFmpeg.integratedLoudness(of: source)
        async let after = FFmpeg.integratedLoudness(of: audio)
        let match = try await min(8, max(-8, before - after))
        try Task.checkCancellation()
        try await run(ffmpeg, ["-hide_banner","-nostdin","-y","-i",source.path,"-i",audio.path,"-map","0:v:0","-map","1:a:0","-map_metadata","0","-c:v","copy","-af","volume=\(match + settings.gain)dB,alimiter=limit=0.89:level=false:latency=true","-c:a","alac","-movflags","+faststart",temporary.path])
        let processed = try await FFmpeg.probe(url: temporary)
        guard original.width == processed.width, original.height == processed.height,
              abs(original.duration - processed.duration) < 0.1 else { throw FFmpegError(message: "Prepared voice media did not preserve the recording timing.") }
        try Task.checkCancellation()
        if FileManager.default.fileExists(atPath: output.path) { try FileManager.default.removeItem(at: output) }
        try FileManager.default.moveItem(at: temporary, to: output)
        let result = VoiceTreatment(settings: settings, source: source, rendered: output, levelMatchDB: match)
        try JSONEncoder().encode(result).write(to: metadata, options: .atomic)
        return result
    }
    private static func sortedData(_ settings: VoiceSettings) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys; return try encoder.encode(settings)
    }
    private static func run(_ ffmpeg: String, _ args: [String]) async throws {
        let r = try await Shell.run(ffmpeg, args)
        guard r.status == 0 else { throw FFmpegError(message: String(r.stderrText.suffix(1200))) }
    }
}

@MainActor extension AppModel {
    func applyVoice(_ settings: VoiceSettings, to id: UUID) {
        guard voicePreparing == nil, let clip = items.first(where: { $0.id == id }) else { return }
        let expected = revision
        voicePreparing = id; voiceError = nil; playback.pause()
        Task {
            defer { voicePreparing = nil }
            do {
                let voice = try await VoiceProcessor.prepare(source: clip.url, settings: settings)
                let result = perform([.setVoice(clip: id, treatment: voice)], label: "Adjust Voice", expectedRevision: expected)
                if case .failure(let error) = result { voiceError = error.localizedDescription }
            } catch { voiceError = error.localizedDescription }
        }
    }
}
