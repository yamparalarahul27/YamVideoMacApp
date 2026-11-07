import Foundation
import AVFoundation

@MainActor func voiceTests() async throws {
    let source = scratch.appendingPathComponent("voice-fixture.mp4")
    let fixture = try await Shell.run(ffmpeg, ["-hide_banner","-loglevel","error","-y","-f","lavfi","-i","color=c=blue:s=320x180:r=30:d=2", "-f","lavfi","-i","aevalsrc=0.12*sin(2*PI*440*t)+0.08*sin(2*PI*3200*t):s=48000:d=2", "-c:v","libx264","-pix_fmt","yuv420p","-c:a","aac","-t","2",source.path])
    check(fixture.status == 0, "voice fixture has two frequency bands")
    var settings = VoiceSettings(); settings.noiseReduction = 0; settings.harshness = 6; settings.warmth = 0; settings.sibilance = 0; settings.compression = 0
    let treatment = try await VoiceProcessor.prepare(source: source, settings: settings)
    defer { if let path = treatment.rendered { try? FileManager.default.removeItem(at: path); try? FileManager.default.removeItem(at: path.appendingPathExtension("json")) } }
    let info = try await FFmpeg.probe(url: source)
    var item = VideoItem(url: source); item.info = info; item.voice = treatment
    equal(item.url, source, "voice leaves the original source reference intact")
    equal(item.effective.url, treatment.rendered!, "player and export effective source is the same treatment")
    equal(item.asRecorded.url, source, "Before uses original source")
    let decoded = try JSONDecoder().decode(ProjectClip.self, from: JSONEncoder().encode(ProjectClip(item)))
    equal(decoded.voice, treatment, "voice settings and prepared path survive project save/load")
    let cached = try await VoiceProcessor.prepare(source: source, settings: settings)
    equal(cached.rendered, treatment.rendered, "same controls reuse deterministic prepared media")
    var bypass = treatment; bypass.settings.enabled = false; item.voice = bypass
    equal(item.effective.url, source, "bypass hears original without losing controls")
    item.voice = treatment
    let renderedInfo = try await FFmpeg.probe(url: treatment.rendered!)
    equal(renderedInfo.width, info.width, "voice treatment preserves video geometry")
    check(abs(renderedInfo.duration - info.duration) < 0.01, "voice treatment preserves source timebase")
    // The video is copied, not re-encoded or retimed.
    func videoHash(_ url: URL) async throws -> String {
        let r = try await Shell.run(ffmpeg,["-v","error","-i",url.path,"-map","0:v","-c","copy","-f","hash","-hash","sha256","-"]);return r.stdoutText
    }
    equal(try await videoHash(source), try await videoHash(treatment.rendered!), "voice processing keeps identical video packets")
    func bandLevel(_ url: URL, _ frequency: Int) async throws -> Double {
        let r = try await Shell.run(ffmpeg,["-hide_banner","-i",url.path,"-vn","-af","bandpass=f=\(frequency):width_type=h:width=120,volumedetect","-f","null","-"])
        let line = r.stderrText.components(separatedBy:"\n").first { $0.contains("mean_volume:") }!
        return Double(line.components(separatedBy:"mean_volume:")[1].trimmingCharacters(in:.whitespaces).components(separatedBy:" ")[0])!
    }
    let beforeRatio = try await bandLevel(source,3200)-bandLevel(source,440)
    let afterRatio = try await bandLevel(treatment.rendered!,3200)-bandLevel(treatment.rendered!,440)
    check(afterRatio < beforeRatio-3, "harshness control reduces upper-mid band relative to voice body")
    let beforeLoudness = try await FFmpeg.integratedLoudness(of: source)
    let afterLoudness = try await FFmpeg.integratedLoudness(of: treatment.rendered!)
    check(abs(beforeLoudness-afterLoudness)<1, "Original/Treated comparison stays loudness matched")
    var smoother = settings; smoother.cutFadeMS = 50
    let reused = try await VoiceProcessor.prepare(source: source, settings: smoother)
    equal(reused.rendered, treatment.rendered, "cut smoothing reuses unchanged voice audio")
    equal(reused.settings.cutFadeMS, 50, "cached media keeps the newly requested cut controls")
    item.segments = [TimelineSegment(start: 0, end: 0.7), TimelineSegment(start: 1, end: 1.8)]
    let project = VideoProject(clips: [ProjectClip(item)], settings: ExportSettings(), selection: item.id)
    let changed = try ProjectReducer.apply([.setVoice(clip: item.id, treatment: reused)], to: project).project
    equal(changed.clips[0].timeline.audioJoints.first?.fade, 0.05, "native playback receives chosen cut smoothing")
    let cuts = changed.clips[0].timeline.segments
    let graph = FFmpeg.sectionAudio(1, cuts, FFmpeg.sectionCuts(cuts, fpsExpression: "30")[1], speedEdits: false)
    check(graph.contains("afade=t=in:d=0.05"), "export uses the same cut smoothing as native playback")
    let reversed = try ProjectReducer.apply([.setVoice(clip: item.id, treatment: nil)], to: changed).project
    check(reversed.clips[0].voice == nil && reversed.clips[0].url == source, "reset removes processing without replacing original source")
    let timingSource = scratch.appendingPathComponent("voice-timing.mov")
    let timingFixture = try await Shell.run(ffmpeg,["-v","error","-y","-i",source.path,"-f","lavfi","-i",#"aevalsrc=0.1*sin(2*PI*(300*t+150*t*t))*between(t\,0.35\,1.65):s=48000:d=2"#,"-map","0:v","-map","1:a","-c:v","copy","-c:a","alac","-t","2",timingSource.path])
    check(timingFixture.status == 0,"creates speech-like transient for sync check",timingFixture.stderrText)
    var clean = settings; clean.noiseReduction = 8; clean.harshness = 0
    let aligned = try await VoiceProcessor.prepare(source: timingSource, settings: clean)
    defer { if let path = aligned.rendered { try? FileManager.default.removeItem(at: path); try? FileManager.default.removeItem(at: path.appendingPathExtension("json")) } }
    func samples(_ url: URL) async throws -> [Float] {
        let r = try await Shell.run(ffmpeg,["-v","error","-i",url.path,"-vn","-ar","2000","-ac","1","-f","f32le","-"])
        return r.stdout.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }
    let drySamples = try await samples(timingSource), wetSamples = try await samples(aligned.rendered!)
    let n = min(drySamples.count,wetSamples.count)-100
    let scores = (-80...80).map { lag in (lag,(100..<n).reduce(0.0) { $0 + Double(drySamples[$1])*Double(wetSamples[$1+lag]) }) }
    let lag = scores.max { $0.1 < $1.1 }!.0
    check(abs(lag)<=5,"noise reduction compensates analysis delay for lip sync","offset \(Double(lag)/2) ms")
    var invalid = settings; invalid.harshness = 99
    do { try invalid.validate(); check(false,"out-of-range settings rejected") } catch { check(true,"out-of-range settings rejected") }
}
