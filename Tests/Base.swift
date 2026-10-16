// What every check shares: the counters, the scratch folder, ffmpeg and the fixture clips.
import AppKit
import AVFoundation
import Foundation

var failures = 0
var checks = 0

func check(_ condition: Bool, _ label: String, _ detail: String = "") {
    checks += 1
    if condition {
        print("  ok   \(label)")
    } else {
        failures += 1
        print("  FAIL \(label)\(detail.isEmpty ? "" : " — \(detail)")")
    }
}

func equal<T: Equatable>(_ actual: T, _ expected: T, _ label: String) {
    check(actual == expected, label, "got \(actual), expected \(expected)")
}

let scratch = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("yamvideo-tests", isDirectory: true)
let ffmpeg = FFmpeg.ffmpegPath ?? "ffmpeg"

// MARK: - Fixtures

func makeClip(_ name: String, size: String, seconds: Double, audio: String?) async throws -> URL {
    let url = scratch.appendingPathComponent(name)
    var args = [
        "-hide_banner", "-loglevel", "error", "-y",
        "-f", "lavfi", "-i", "testsrc2=size=\(size):rate=30",
    ]
    if let audio {
        args += ["-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000", "-c:a", audio]
    }
    args += ["-t", String(seconds), "-c:v", "libx264", "-pix_fmt", "yuv420p", url.path]
    let result = try await Shell.run(ffmpeg, args)
    guard result.status == 0 else {
        throw FFmpegError(message: "fixture \(name) failed: \(result.stderrText)")
    }
    return url
}

/// The clips most checks use, made once before the features run.
private var storedLandscape: URL?, storedPCMClip: URL?, storedInfo: MediaInfo?, storedPCMInfo: MediaInfo?
var landscape: URL { storedLandscape! }
var pcmClip: URL { storedPCMClip! }
var info: MediaInfo { storedInfo! }
var pcmInfo: MediaInfo { storedPCMInfo! }
/// A clip carrying 90° rotation metadata, mimicking iPhone footage.
var rotated: URL?

func makeFixtures() async throws {
    print("Fixtures")
    storedLandscape = try await makeClip("landscape.mov", size: "1280x720", seconds: 3, audio: "aac")
    storedPCMClip = try await makeClip("pcm.mov", size: "640x480", seconds: 1, audio: "pcm_s16le")
    check(FileManager.default.fileExists(atPath: landscape.path), "created 1280x720 MOV with AAC audio")
    check(FileManager.default.fileExists(atPath: pcmClip.path), "created 640x480 MOV with PCM audio")
    let url = scratch.appendingPathComponent("rotated.mov")
    let result = try await Shell.run(ffmpeg, ["-hide_banner", "-loglevel", "error", "-y", "-display_rotation", "90",
                                              "-i", landscape.path, "-c", "copy", url.path])
    if result.status == 0 { rotated = url }
    check(rotated != nil, "created a clip with 90° rotation metadata")
    storedInfo = try await FFmpeg.probe(url: landscape)
    storedPCMInfo = try await FFmpeg.probe(url: pcmClip)
    try FileManager.default.createDirectory(at: colorScratch, withIntermediateDirectories: true)
}

// MARK: - Shared values

/// The repository, for the checks that read its files.
let repository = ProcessInfo.processInfo.environment["YAMVIDEO_ROOT"] ?? FileManager.default.currentDirectoryPath
let nodeBinary = ["/opt/homebrew/bin/node", "/usr/local/bin/node"].first { FileManager.default.isExecutableFile(atPath: $0) }
let srt = scratch.appendingPathComponent("captions.srt")
let colorScratch = scratch.appendingPathComponent("colour", isDirectory: true)
let namedProject = scratch.appendingPathComponent("round-trip.yamvideo")
let bestQuality: ExportSettings = { var settings = ExportSettings(); settings.quality = 100; return settings }()
/// The test bridge's own instance, for the agent checks' in-process requests.
let bridgeInstance = UUID()
/// Analysis frames: grey, and grey with a small bright square.
let still = [UInt8](repeating: 70, count: ZoomAnalyzer.width * ZoomAnalyzer.height)
let active: [UInt8] = {
    var frame = still
    for y in 30..<40 { for x in 120..<130 { frame[y * ZoomAnalyzer.width + x] = 220 } }
    return frame
}()
/// The colour chart's grid of patches.
let chartColumns = 8, chartRows = 6, patchWidth = 160, patchHeight = 120

/// The editing checks' project, which the agent and playback checks start from.
private var storedRoundTrip: VideoProject?
var roundTripProject: VideoProject {
    get { storedRoundTrip! }
    set { storedRoundTrip = newValue }
}
/// A second recording of the landscape clip, for colour, effects, graphics and publishing.
private var storedGradeOther: VideoItem?
var gradeOther: VideoItem {
    get {
        if storedGradeOther == nil {
            var item = VideoItem(url: landscape); item.info = info; item.crop = info.fullFrame
            storedGradeOther = item
        }
        return storedGradeOther!
    }
    set { storedGradeOther = newValue }
}

// MARK: - Shared clips, each made once by whichever feature needs it first

private var storedMarker: (clip: URL, info: MediaInfo)?
/// A clip with a small red marker, so a zoom can be measured rather than eyeballed.
func markerFixture() async throws -> (clip: URL, info: MediaInfo) {
    if let storedMarker { return storedMarker }
    let clip = scratch.appendingPathComponent("marker.mov")
    _ = try await Shell.run(ffmpeg, [
        "-hide_banner", "-loglevel", "error", "-y",
        "-f", "lavfi", "-i", "color=gray:s=1280x720:r=30", "-t", "3",
        "-vf", "drawbox=900:500:60:60:red@1:t=fill",
        "-c:v", "libx264", "-crf", "18", "-pix_fmt", "yuv420p", clip.path,
    ])
    storedMarker = (clip, try await FFmpeg.probe(url: clip))
    return storedMarker!
}

private var storedActivity: (file: URL, clip: VideoItem)?
/// A 24 fps clip with a white square that shows from 1 s to 2 s.
func activityFixture() async throws -> (file: URL, clip: VideoItem) {
    if let storedActivity { return storedActivity }
    let file = scratch.appendingPathComponent("activity.mp4")
    let result = try await Shell.run(ffmpeg, ["-v", "error", "-y", "-f", "lavfi", "-i",
        "color=c=gray:s=320x180:r=24:d=4,drawbox=x=240:y=60:w=20:h=20:color=white:t=fill:enable='between(t,1,2)'",
        "-c:v", "libx264", "-pix_fmt", "yuv420p", file.path])
    equal(result.status, 0, "created a localized activity fixture at 24 fps")
    var clip = VideoItem(url: file)
    clip.info = try await FFmpeg.probe(url: file)
    storedActivity = (file, clip)
    return storedActivity!
}

private var storedMove: (clip: URL, info: MediaInfo, track: GraphicsTrack)?
/// A textured 10-bit 4:4:4 Rec.709 clip, so neither renderer guesses chroma or matrix,
/// with two rules that move the picture aside.
func moveFixture() async throws -> (clip: URL, info: MediaInfo, track: GraphicsTrack) {
    if let storedMove { return storedMove }
    let clip = scratch.appendingPathComponent("move.mov")
    let encode = try await Shell.run(ffmpeg, ["-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi", "-i", "testsrc2=size=1280x720:rate=30",
        "-t", "4.5", "-vf", "scale=out_color_matrix=bt709:out_range=tv:flags=accurate_rnd+full_chroma_int,format=yuv444p10le",
        "-c:v", "prores_ks", "-profile:v", "4444", "-color_primaries", "bt709", "-color_trc", "bt709",
        "-colorspace", "bt709", "-color_range", "tv", clip.path])
    check(encode.status == 0, "made a textured Rec.709 clip", encode.stderrText)
    var track = GraphicsTrack(items: [gfx(.rule, 1.0, 2.0), gfx(.rule, 3.2, 3.8, look: .ink)])
    track.style.panel = .shade
    storedMove = (clip, try await FFmpeg.probe(url: clip), track)
    return storedMove!
}

private var storedSubject: (frame: URL, clip: URL, item: VideoItem)?
/// A frame with a clear subject on the left (a head and a body on grey), and a 2 s
/// recording of it.
func subjectFixture() async throws -> (frame: URL, clip: URL, item: VideoItem) {
    if let storedSubject { return storedSubject }
    let frame = scratch.appendingPathComponent("subject.png")
    let made = try await Shell.run(ffmpeg, ["-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi", "-i", "color=c=0x8a9099:s=1280x720,format=rgb24",
        "-vf", "geq=r='if(lt(hypot(X-420,Y-420),220),220,if(lt(hypot(X-420,Y-160),110),230,138))':g='if(lt(hypot(X-420,Y-420),220),60,if(lt(hypot(X-420,Y-160),110),180,144))':b='if(lt(hypot(X-420,Y-420),220),50,if(lt(hypot(X-420,Y-160),110),150,153))'",
        "-frames:v", "1", frame.path])
    check(made.status == 0, "made a frame with a subject", made.stderrText)
    let clip = scratch.appendingPathComponent("subject.mov")
    let video = try await Shell.run(ffmpeg, ["-hide_banner", "-loglevel", "error", "-y", "-loop", "1", "-i", frame.path, "-t", "2",
                                             "-r", "30", "-c:v", "libx264", "-pix_fmt", "yuv420p", "-colorspace", "bt709", "-color_primaries", "bt709",
                                             "-color_trc", "bt709", clip.path])
    check(video.status == 0, "made a recording of the subject", video.stderrText)
    var item = VideoItem(url: clip)
    item.info = try await FFmpeg.probe(url: clip); item.crop = item.info!.fullFrame
    storedSubject = (frame, clip, item)
    return storedSubject!
}


// MARK: - Colour frames, for the colour and effect checks

struct RGBFrame { let width: Int, height: Int; let values: [Double]
    func patch(_ index: Int, inset: Int = 40) -> [SIMD3<Double>] {
        let left = (index % chartColumns) * patchWidth + inset, top = (index / chartColumns) * patchHeight + inset
        var pixels: [SIMD3<Double>] = []
        for y in top..<(top + patchHeight - 2 * inset) { for x in left..<(left + patchWidth - 2 * inset) {
            let i = (y * width + x) * 3
            pixels.append(SIMD3(values[i], values[i + 1], values[i + 2]))
        } }
        return pixels
    }
}


/// A thumbnail's pixels as 0–255 RGB.
func thumbFrame(_ image: NSImage) -> RGBFrame {
    let frame = image.cgImage(forProposedRect: nil, context: nil, hints: nil)!
    let space = frame.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
    var words = [UInt16](repeating: 0, count: frame.width * frame.height * 4)
    let context = CGContext(data: &words, width: frame.width, height: frame.height, bitsPerComponent: 16, bytesPerRow: frame.width * 8,
                            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue)!
    context.draw(frame, in: CGRect(x: 0, y: 0, width: frame.width, height: frame.height))
    var values: [Double] = []
    for pixel in stride(from: 0, to: words.count, by: 4) {
        values += [Double(words[pixel]) / 65535, Double(words[pixel + 1]) / 65535, Double(words[pixel + 2]) / 65535]
    }
    return RGBFrame(width: frame.width, height: frame.height, values: values)
}

