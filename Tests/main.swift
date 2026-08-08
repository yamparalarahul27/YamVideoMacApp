// End-to-end checks for the pieces the app relies on: ffprobe parsing, crop maths,
// argument building, progress reporting and the real encode.
// Run with ./test.sh
import AppKit
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

let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("yamvideo-tests", isDirectory: true)
try? FileManager.default.removeItem(at: scratch)
try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)

guard let ffmpeg = FFmpeg.ffmpegPath, FFmpeg.ffprobePath != nil else {
    print("ffmpeg/ffprobe not found — cannot run tests")
    exit(2)
}
print("using \(ffmpeg)\n")

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

print("Fixtures")
let landscape = try await makeClip("landscape.mov", size: "1280x720", seconds: 3, audio: "aac")
let pcmClip = try await makeClip("pcm.mov", size: "640x480", seconds: 1, audio: "pcm_s16le")
check(FileManager.default.fileExists(atPath: landscape.path), "created 1280x720 MOV with AAC audio")
check(FileManager.default.fileExists(atPath: pcmClip.path), "created 640x480 MOV with PCM audio")

// A clip carrying 90° rotation metadata, mimicking iPhone footage.
var rotated: URL?
do {
    let url = scratch.appendingPathComponent("rotated.mov")
    let result = try await Shell.run(ffmpeg, [
        "-hide_banner", "-loglevel", "error", "-y",
        "-display_rotation", "90", "-i", landscape.path,
        "-c", "copy", url.path,
    ])
    if result.status == 0 { rotated = url }
}
check(rotated != nil, "created a clip with 90° rotation metadata")

// MARK: - Probing

print("\nProbe")
let info = try await FFmpeg.probe(url: landscape)
equal(info.width, 1280, "landscape width")
equal(info.height, 720, "landscape height")
equal(info.videoCodec, "h264", "video codec")
equal(info.audioCodec, "aac", "audio codec")
check(abs(info.duration - 3) < 0.2, "duration ≈ 3s", "got \(info.duration)")
check(abs(info.fps - 30) < 0.5, "fps ≈ 30", "got \(info.fps)")
check(info.hasAudio, "detects audio track")

let pcmInfo = try await FFmpeg.probe(url: pcmClip)
equal(pcmInfo.audioCodec, "pcm_s16le", "PCM audio detected")

if let rotated {
    let rotatedInfo = try await FFmpeg.probe(url: rotated)
    equal(abs(rotatedInfo.rotation) % 180, 90, "rotation metadata read")
    // ffmpeg auto-rotates before filters, so the crop space must be the *displayed* frame.
    equal(rotatedInfo.width, 720, "rotated display width is swapped")
    equal(rotatedInfo.height, 1280, "rotated display height is swapped")
}

do {
    let bogus = scratch.appendingPathComponent("not-a-video.mov")
    try Data("nonsense".utf8).write(to: bogus)
    _ = try await FFmpeg.probe(url: bogus)
    check(false, "unreadable file throws")
} catch {
    check(true, "unreadable file throws")
}

// MARK: - Crop maths

print("\nCrop maths")
let bounds = info.fullFrame
equal(CGRect(x: 11, y: 9, width: 641, height: 361).evenClamped(in: bounds),
      CGRect(x: 10, y: 8, width: 640, height: 360), "odd values snap to even")
equal(CGRect(x: 1200, y: 700, width: 400, height: 400).evenClamped(in: bounds),
      CGRect(x: 880, y: 320, width: 400, height: 400), "oversized rect is pushed inside bounds")
equal(CGRect(x: -50, y: -50, width: 200, height: 100).evenClamped(in: bounds),
      CGRect(x: 0, y: 0, width: 200, height: 100), "negative origin is clamped")

let sixteenNine = CGRect.centered(aspect: 16.0 / 9.0, in: bounds)
check(abs(sixteenNine.width / sixteenNine.height - 16.0 / 9.0) < 0.01, "centred 16:9 keeps ratio")
equal(sixteenNine.width, 1280, "centred 16:9 fills the width of a 16:9 frame")

let square = CGRect.centered(aspect: 1, in: bounds)
equal(square, CGRect(x: 280, y: 0, width: 720, height: 720), "centred 1:1 inside 16:9")

// Aspect-locked resize keeps the ratio and stays in bounds.
let start = CGRect(x: 100, y: 100, width: 400, height: 225)
for delta in [CGSize(width: 500, height: 0), CGSize(width: -300, height: -300),
              CGSize(width: 5000, height: 5000), CGSize(width: -5000, height: -5000)] {
    for handle in CropHandle.allCases {
        let result = resizedCrop(start: start, handle: handle, delta: delta,
                                 ratio: 16.0 / 9.0, bounds: bounds)
        let ratioOK = abs(result.width / result.height - 16.0 / 9.0) < 0.05
        let insideOK = result.minX >= -0.01 && result.minY >= -0.01
            && result.maxX <= bounds.maxX + 0.01 && result.maxY <= bounds.maxY + 0.01
        check(ratioOK && insideOK, "locked resize \(handle) Δ\(Int(delta.width)),\(Int(delta.height))",
              "\(result) ratio=\(result.width / max(result.height, 1))")
    }
}

// Free resize also respects the minimum side and bounds.
let collapsed = resizedCrop(start: start, handle: .bottomRight,
                            delta: CGSize(width: -9999, height: -9999), ratio: nil, bounds: bounds)
check(collapsed.width >= 16 && collapsed.height >= 16, "free resize honours minimum side",
      "\(collapsed)")

// MARK: - Scaling

print("\nScale limits")
check(FFmpeg.scaledSize(for: CGSize(width: 1280, height: 720), limit: .fhd) == nil,
      "no upscale when already under the limit")
equal(FFmpeg.scaledSize(for: CGSize(width: 3840, height: 2160), limit: .fhd),
      CGSize(width: 1920, height: 1080), "4K down to 1080p")
equal(FFmpeg.scaledSize(for: CGSize(width: 1080, height: 1920), limit: .hd),
      CGSize(width: 720, height: 1280), "portrait limits the long side")
if let odd = FFmpeg.scaledSize(for: CGSize(width: 1919, height: 1079), limit: .hd) {
    check(Int(odd.width) % 2 == 0 && Int(odd.height) % 2 == 0, "scaled dimensions stay even", "\(odd)")
}

// MARK: - Argument building

print("\nArguments")
var settings = ExportSettings()
let fullFrameArgs = FFmpeg.exportArguments(
    input: landscape, output: scratch.appendingPathComponent("x.mp4"),
    info: info, crop: info.fullFrame, settings: settings)
check(!fullFrameArgs.contains("-vf"), "no filter chain when nothing is cropped or scaled")
check(fullFrameArgs.contains("+faststart"), "faststart is always set")

let croppedArgs = FFmpeg.exportArguments(
    input: landscape, output: scratch.appendingPathComponent("x.mp4"),
    info: info, crop: CGRect(x: 11, y: 9, width: 641, height: 361), settings: settings)
if let index = croppedArgs.firstIndex(of: "-vf") {
    equal(croppedArgs[index + 1], "crop=640:360:10:8", "crop filter uses even values")
} else {
    check(false, "crop filter present")
}

settings.encoder = .hevcVT
check(FFmpeg.exportArguments(input: landscape, output: scratch.appendingPathComponent("x.mp4"),
                            info: info, crop: info.fullFrame, settings: settings)
        .contains("hvc1"), "HEVC gets the hvc1 tag for QuickTime")

settings = ExportSettings()
settings.audio = .none
check(FFmpeg.exportArguments(input: landscape, output: scratch.appendingPathComponent("x.mp4"),
                            info: info, crop: info.fullFrame, settings: settings).contains("-an"),
      "audio removal passes -an")

equal(ExportSettings().crf, 19, "default quality maps to CRF 19")

// MARK: - Blur filter graph

print("\nBlur filter graph")
let r1 = CGRect(x: 100, y: 60, width: 200, height: 120)
let r2 = CGRect(x: 700, y: 400, width: 160, height: 160)

check(FFmpeg.filterGraph(regions: [], style: .blur, strength: 20, tail: []) == nil,
      "no regions and no tail means no filter at all")

if let simple = FFmpeg.filterGraph(regions: [], style: .blur, strength: 20, tail: ["crop=2:2:0:0"]) {
    check(!simple.isComplex, "a tail with no regions stays a simple -vf chain")
}

if let boxes = FFmpeg.filterGraph(regions: [r1, r2], style: .black, strength: 20, tail: []) {
    check(!boxes.isComplex, "black boxes need no filter_complex")
    equal(boxes.spec,
          "drawbox=100:60:200:120:color=black:t=fill,drawbox=700:400:160:160:color=black:t=fill",
          "drawbox chain covers each region")
}

if let one = FFmpeg.filterGraph(regions: [r1], style: .blur, strength: 20, tail: []) {
    check(one.isComplex, "blur needs filter_complex")
    equal(one.outputLabel, "vout", "graph exposes an output pad")
    equal(one.spec,
          "[0:v]split=2[base][t0];[t0]crop=200:120:100:60,gblur=sigma=20[b0];[base][b0]overlay=100:60[vout]",
          "single-region blur graph")
}

if let two = FFmpeg.filterGraph(regions: [r1, r2], style: .blur, strength: 20,
                                tail: ["crop=640:360:100:100"]) {
    check(two.spec.contains("split=3[base][t0][t1]"), "splits once per region plus the base")
    check(two.spec.contains("overlay=100:60") && two.spec.contains("overlay=700:400"),
          "each region is composited back at its own offset")
    check(two.spec.hasSuffix("[ov]crop=640:360:100:100[vout]"),
          "the crop runs last, after the regions are blurred", two.spec)
}

if let pix = FFmpeg.filterGraph(regions: [r1], style: .pixelate, strength: 20, tail: []) {
    // block = 20/2 = 10 -> 200x120 becomes 20x12, then back up with nearest neighbour.
    check(pix.spec.contains("scale=20:12,scale=200:120:flags=neighbor"),
          "pixelate computes exact block dimensions", pix.spec)
}

// MARK: - Output naming

print("\nOutput naming")
settings = ExportSettings()
let firstOut = FFmpeg.outputURL(for: landscape, settings: settings)
equal(firstOut.lastPathComponent, "landscape-converted.mp4", "derives the output name")
try Data().write(to: firstOut)
equal(FFmpeg.outputURL(for: landscape, settings: settings).lastPathComponent,
      "landscape-converted-2.mp4", "avoids overwriting an existing file")
try FileManager.default.removeItem(at: firstOut)

let mp4Source = scratch.appendingPathComponent("clash.mp4")
try Data().write(to: mp4Source)
var noSuffix = ExportSettings()
noSuffix.suffix = ""
check(FFmpeg.outputURL(for: mp4Source, settings: noSuffix).path != mp4Source.path,
      "never writes over the source file")

// MARK: - Real encodes

print("\nEncode")
var progressValues: [Double] = []
let cropped = CGRect(x: 100, y: 60, width: 641, height: 361)
let out1 = scratch.appendingPathComponent("out-crop.mp4")
try await FFmpeg.export(input: landscape, output: out1, info: info,
                        crop: cropped, settings: ExportSettings()) { progressValues.append($0) }

let out1Info = try await FFmpeg.probe(url: out1)
equal(out1Info.width, 640, "cropped output width")
equal(out1Info.height, 360, "cropped output height")
equal(out1Info.videoCodec, "h264", "output is H.264")
equal(out1Info.audioCodec, "aac", "output audio is AAC")
check(abs(out1Info.duration - info.duration) < 0.3, "duration preserved", "got \(out1Info.duration)")
check(progressValues.count > 1, "progress reported \(progressValues.count) updates")
check(progressValues == progressValues.sorted(), "progress never goes backwards")
equal(progressValues.last, 1.0, "progress finishes at 100%")

// Crop + downscale together.
var scaled = ExportSettings()
scaled.sizeLimit = .sd
scaled.suffix = "-small"
let out2 = FFmpeg.outputURL(for: landscape, settings: scaled)
try await FFmpeg.export(input: landscape, output: out2, info: info,
                        crop: CGRect(x: 0, y: 0, width: 1280, height: 720), settings: scaled) { _ in }
let out2Info = try await FFmpeg.probe(url: out2)
equal(out2Info.width, 854, "downscaled width")
equal(out2Info.height, 480, "downscaled height")

// Hardware encoder path.
var hw = ExportSettings()
hw.encoder = .h264VT
hw.suffix = "-vt"
let out3 = FFmpeg.outputURL(for: landscape, settings: hw)
do {
    try await FFmpeg.export(input: landscape, output: out3, info: info,
                            crop: CGRect(x: 0, y: 0, width: 900, height: 600), settings: hw) { _ in }
    let out3Info = try await FFmpeg.probe(url: out3)
    equal(out3Info.width, 900, "VideoToolbox output width")
    equal(out3Info.videoCodec, "h264", "VideoToolbox output is H.264")
} catch {
    check(false, "VideoToolbox encode", error.localizedDescription)
}

// Rotated source: crop coordinates must line up with the displayed (portrait) frame.
if let rotated {
    let rotatedInfo = try await FFmpeg.probe(url: rotated)
    var s = ExportSettings()
    s.suffix = "-rot"
    let out4 = FFmpeg.outputURL(for: rotated, settings: s)
    try await FFmpeg.export(input: rotated, output: out4, info: rotatedInfo,
                            crop: CGRect(x: 0, y: 100, width: 720, height: 900),
                            settings: s) { _ in }
    let out4Info = try await FFmpeg.probe(url: out4)
    equal(out4Info.width, 720, "rotated crop width matches the displayed frame")
    equal(out4Info.height, 900, "rotated crop height matches the displayed frame")
    equal(out4Info.rotation, 0, "rotation is baked in, not re-tagged")
}

// MARK: - Blur encodes

print("\nBlur encodes")

/// Reads one pixel out of a rendered frame.
func pixel(_ url: URL, x: Int, y: Int, at time: Double = 1.0) async throws -> (Int, Int, Int) {
    let result = try await Shell.run(ffmpeg, [
        "-hide_banner", "-loglevel", "error",
        "-ss", String(format: "%.3f", time), "-i", url.path,
        "-frames:v", "1", "-vf", "crop=2:2:\(x):\(y)",
        "-f", "rawvideo", "-pix_fmt", "rgb24", "-",
    ])
    let bytes = [UInt8](result.stdout)
    guard bytes.count >= 3 else { throw FFmpegError(message: "no pixel data at \(x),\(y)") }
    return (Int(bytes[0]), Int(bytes[1]), Int(bytes[2]))
}

// Geometry: a black box plus a crop. The box must land at (box - cropOrigin) in the output,
// and untouched pixels must still match the source. This pins down both coordinate spaces.
var blackSettings = ExportSettings()
blackSettings.blurStyle = .black
blackSettings.suffix = "-black"
let blackOut = FFmpeg.outputURL(for: landscape, settings: blackSettings)
let box = CGRect(x: 200, y: 100, width: 160, height: 120)
let boxCrop = CGRect(x: 100, y: 50, width: 640, height: 480)
try await FFmpeg.export(input: landscape, output: blackOut, info: info,
                        crop: boxCrop, regions: [box], settings: blackSettings) { _ in }
let blackInfo = try await FFmpeg.probe(url: blackOut)
equal(blackInfo.width, 640, "cropped output width with a black box")

let insideBox = try await pixel(blackOut, x: 150, y: 100)   // box origin in output is (100,50)
check(insideBox.0 < 30 && insideBox.1 < 30 && insideBox.2 < 30,
      "the covered area is black in the output", "rgb\(insideBox)")

let sourcePixel = try await pixel(landscape, x: 110, y: 60)
let outsideBox = try await pixel(blackOut, x: 10, y: 10)     // == source (110, 60)
let delta = max(abs(sourcePixel.0 - outsideBox.0),
                max(abs(sourcePixel.1 - outsideBox.1), abs(sourcePixel.2 - outsideBox.2)))
check(delta < 40, "pixels outside the box survive the crop unchanged",
      "source rgb\(sourcePixel) vs output rgb\(outsideBox)")

// Does the region actually lose its detail? Measure sharpness directly as the mean
// absolute difference between horizontally adjacent pixels — blurring flattens it.
func regionDetail(_ url: URL, _ rect: CGRect, at time: Double = 1.0) async throws -> Double {
    let result = try await Shell.run(ffmpeg, [
        "-hide_banner", "-loglevel", "error",
        "-ss", String(format: "%.3f", time), "-i", url.path, "-frames:v", "1",
        "-vf", "crop=\(Int(rect.width)):\(Int(rect.height)):\(Int(rect.minX)):\(Int(rect.minY))",
        "-f", "rawvideo", "-pix_fmt", "gray", "-",
    ])
    let bytes = [UInt8](result.stdout)
    let w = Int(rect.width), h = Int(rect.height)
    guard bytes.count >= w * h, w > 1 else {
        throw FFmpegError(message: "short frame data for \(rect)")
    }
    var total = 0.0
    var count = 0
    for row in 0..<h {
        let base = row * w
        for i in 1..<w {
            total += abs(Double(bytes[base + i]) - Double(bytes[base + i - 1]))
            count += 1
        }
    }
    return total / Double(max(count, 1))
}

// testsrc2 has large flat areas, so detail tests use a fine checkerboard instead.
let detailClip = scratch.appendingPathComponent("detail.mov")
_ = try await Shell.run(ffmpeg, [
    "-hide_banner", "-loglevel", "error", "-y",
    "-f", "lavfi", "-i", "color=black:s=1280x720:r=30", "-t", "2",
    "-vf", "format=yuv420p,geq=lum='if(mod(floor(X/8)+floor(Y/8),2),235,16)':cb=128:cr=128",
    "-c:v", "libx264", "-crf", "18", "-pix_fmt", "yuv420p", detailClip.path,
])
let detailInfo = try await FFmpeg.probe(url: detailClip)
let sourceDetail = try await regionDetail(detailClip, r1)
check(sourceDetail > 20, "the detail fixture really is high-frequency",
      String(format: "%.1f", sourceDetail))

var blurSettings = ExportSettings()
blurSettings.suffix = "-blur"
let blurOut = FFmpeg.outputURL(for: detailClip, settings: blurSettings)
try await FFmpeg.export(input: detailClip, output: blurOut, info: detailInfo,
                        crop: detailInfo.fullFrame, regions: [r1, r2], settings: blurSettings) { _ in }
let blurInfo = try await FFmpeg.probe(url: blurOut)
equal(blurInfo.width, 1280, "blur alone leaves the frame size alone")

let blurredDetail = try await regionDetail(blurOut, r1)
check(blurredDetail < sourceDetail * 0.1, "the blurred area lost its detail",
      String(format: "%.1f -> %.1f", sourceDetail, blurredDetail))
let secondRegionDetail = try await regionDetail(blurOut, r2)
check(secondRegionDetail < sourceDetail * 0.1, "the second region is blurred too",
      String(format: "%.1f", secondRegionDetail))
let untouchedDetail = try await regionDetail(blurOut, CGRect(x: 950, y: 80, width: 200, height: 120))
check(untouchedDetail > sourceDetail * 0.7, "areas outside the regions keep their detail",
      String(format: "%.1f vs %.1f", untouchedDetail, sourceDetail))

// -filter_complex disables automatic stream selection: audio must be mapped explicitly.
let blurredWithAudio = FFmpeg.outputURL(for: landscape, settings: blurSettings)
try await FFmpeg.export(input: landscape, output: blurredWithAudio, info: info,
                        crop: info.fullFrame, regions: [r1], settings: blurSettings) { _ in }
equal(try await FFmpeg.probe(url: blurredWithAudio).audioCodec, "aac",
      "audio survives a filter_complex blur graph")

var blurNoAudio = ExportSettings()
blurNoAudio.audio = .none
blurNoAudio.suffix = "-blur-silent"
let silentOut = FFmpeg.outputURL(for: landscape, settings: blurNoAudio)
try await FFmpeg.export(input: landscape, output: silentOut, info: info,
                        crop: info.fullFrame, regions: [r1], settings: blurNoAudio) { _ in }
check(try await FFmpeg.probe(url: silentOut).audioCodec == nil,
      "removing audio still works with a blur graph")

// Pixelate through a real encode.
var pixSettings = ExportSettings()
pixSettings.blurStyle = .pixelate
pixSettings.suffix = "-pixel"
let pixOut = FFmpeg.outputURL(for: detailClip, settings: pixSettings)
try await FFmpeg.export(input: detailClip, output: pixOut, info: detailInfo,
                        crop: detailInfo.fullFrame, regions: [r1], settings: pixSettings) { _ in }
check(try await FFmpeg.probe(url: pixOut).width == 1280, "pixelate encodes cleanly")
let pixDetail = try await regionDetail(pixOut, r1)
check(pixDetail < sourceDetail * 0.2, "the pixelated area lost its detail",
      String(format: "%.1f -> %.1f", sourceDetail, pixDetail))

// Blur regions on rotated footage use displayed coordinates, same as the crop.
if let rotated {
    let rotatedInfo = try await FFmpeg.probe(url: rotated)
    var s = ExportSettings()
    s.blurStyle = .black
    s.suffix = "-rotblur"
    let out = FFmpeg.outputURL(for: rotated, settings: s)
    // Portrait frame is 720x1280; this box only fits in the displayed orientation.
    let portraitBox = CGRect(x: 100, y: 900, width: 300, height: 200)
    try await FFmpeg.export(input: rotated, output: out, info: rotatedInfo,
                            crop: rotatedInfo.fullFrame, regions: [portraitBox], settings: s) { _ in }
    let px = try await pixel(out, x: 200, y: 1000)
    check(px.0 < 30 && px.1 < 30 && px.2 < 30,
          "blur box lands correctly on rotated footage", "rgb\(px)")
}

// The preview bakes in the same blur, so what you see is what you get.
let blurredThumb = try await FFmpeg.thumbnail(url: landscape, at: 1.0, duration: info.duration,
                                              regions: [r1], style: .black, strength: 24)
check(blurredThumb.count > 1000, "preview frame renders with blur applied")
check(Array(blurredThumb.prefix(4)) == [0x89, 0x50, 0x4E, 0x47], "preview frame is still PNG")

// Audio compatibility: ffmpeg 8 *will* copy PCM into MP4 (as `ipcm`), but QuickTime
// cannot decode it — so the app flags it rather than relying on an ffmpeg error.
print("\nAudio compatibility")
check(!pcmInfo.audioIsMP4Compatible, "PCM audio is flagged as MP4-incompatible")
check(info.audioIsMP4Compatible, "AAC audio is allowed to be copied")
var copySettings = ExportSettings()
copySettings.audio = .copy
copySettings.suffix = "-pcmcopy"
let copyOut = FFmpeg.outputURL(for: pcmClip, settings: copySettings)
try await FFmpeg.export(input: pcmClip, output: copyOut, info: pcmInfo,
                        crop: pcmInfo.fullFrame, settings: copySettings) { _ in }
let copyInfo = try await FFmpeg.probe(url: copyOut)
equal(copyInfo.audioCodec, "pcm_s16le", "copied stream is passed through untouched")

// A failing encode must surface the error and leave no partial file behind.
print("\nFailure handling")
let unwritable = URL(fileURLWithPath: "/no-such-directory-xyz/out.mp4")
do {
    try await FFmpeg.export(input: landscape, output: unwritable, info: info,
                            crop: info.fullFrame, settings: ExportSettings()) { _ in }
    check(false, "an unwritable destination reports an error")
} catch {
    check(!error.localizedDescription.isEmpty, "an unwritable destination reports an error",
          error.localizedDescription.split(separator: "\n").last.map(String.init) ?? "")
}

// A bad encoder argument must be reported rather than leaving a truncated file.
var brokenSettings = ExportSettings()
brokenSettings.preset = "not-a-real-preset"
brokenSettings.suffix = "-broken"
let brokenOut = FFmpeg.outputURL(for: landscape, settings: brokenSettings)
do {
    try await FFmpeg.export(input: landscape, output: brokenOut, info: info,
                            crop: info.fullFrame, settings: brokenSettings) { _ in }
    check(false, "an invalid encoder setting reports an error")
} catch {
    check(!error.localizedDescription.isEmpty, "an invalid encoder setting reports an error")
    check(!FileManager.default.fileExists(atPath: brokenOut.path), "no partial file is left behind")
}

// Cancellation.
let cancelTarget = scratch.appendingPathComponent("cancelled.mp4")
var slow = ExportSettings()
slow.preset = "veryslow"
slow.quality = 100
let long = try await makeClip("long.mov", size: "1920x1080", seconds: 20, audio: "aac")
let longInfo = try await FFmpeg.probe(url: long)
let task = Task {
    try await FFmpeg.export(input: long, output: cancelTarget, info: longInfo,
                            crop: longInfo.fullFrame, settings: slow) { _ in }
}
try await Task.sleep(nanoseconds: 1_500_000_000)
task.cancel()
do {
    try await task.value
    check(false, "cancellation stops the encode")
} catch {
    check(error is CancellationError || !error.localizedDescription.isEmpty,
          "cancellation stops the encode")
    check(!FileManager.default.fileExists(atPath: cancelTarget.path),
          "cancelled encode removes its partial output")
}

// MARK: - Thumbnails

print("\nThumbnails")
let thumb = try await FFmpeg.thumbnail(url: landscape, at: 1.0, duration: info.duration)
check(thumb.count > 1000, "grabbed a PNG frame (\(thumb.count) bytes)")
check(Array(thumb.prefix(4)) == [0x89, 0x50, 0x4E, 0x47], "frame really is PNG")

// Seeking to the very end of a clip decodes nothing unless it is clamped.
let endThumb = try? await FFmpeg.thumbnail(url: landscape, at: info.duration, duration: info.duration)
check(endThumb != nil, "scrubbing to the very end still returns a frame")
let pastEnd = try? await FFmpeg.thumbnail(url: landscape, at: info.duration * 4, duration: info.duration)
check(pastEnd != nil, "a seek past the end falls back to a valid frame")
let noDuration = try? await FFmpeg.thumbnail(url: landscape, at: 99)
check(noDuration != nil, "an out-of-range seek with no duration hint falls back to frame 0")

let portraitThumb = try? await FFmpeg.thumbnail(url: rotated ?? landscape, at: 0.5, duration: 3)
check(portraitThumb != nil, "can grab a frame from a rotated clip")
if let portraitThumb, let rep = NSBitmapImageRep(data: portraitThumb), rotated != nil {
    check(rep.pixelsWide < rep.pixelsHigh, "rotated preview frame comes back portrait",
          "\(rep.pixelsWide)x\(rep.pixelsHigh)")
}

print("\n\(checks - failures)/\(checks) checks passed")
try? FileManager.default.removeItem(at: scratch)
exit(failures == 0 ? 0 : 1)
