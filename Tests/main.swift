// End-to-end checks for the pieces the app relies on: ffprobe parsing, crop maths,
// argument building, progress reporting and the real encode.
// Run with ./test.sh
import AppKit
import AVFoundation
import Foundation

setbuf(stdout, nil)

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

// MARK: - Zoom

print("\nZoom filter")
let shot = ZoomShot(start: 0.5, hold: 1.0, level: 2, target: CGPoint(x: 930, y: 530))
equal(shot.duration, 2.0, "duration is hold plus both eases")
equal(shot.end, 2.5, "end time")
check(shot.overlaps(ZoomShot(start: 2.0, hold: 1, level: 2, target: .zero)),
      "overlapping shots are detected")
check(!shot.overlaps(ZoomShot(start: 2.6, hold: 1, level: 2, target: .zero)),
      "adjacent shots do not count as overlapping")

check(FFmpeg.zoomFilter(shots: [], frame: CGSize(width: 1280, height: 720),
                        cropOrigin: .zero, fpsExpression: "30") == nil,
      "no shots means no zoom filter")
check(FFmpeg.zoomFilter(shots: [ZoomShot(start: 0, hold: 1, level: 1, target: .zero)],
                        frame: CGSize(width: 1280, height: 720),
                        cropOrigin: .zero, fpsExpression: "30") == nil,
      "a 1x zoom is not a zoom")

if let zf = FFmpeg.zoomFilter(shots: [shot], frame: CGSize(width: 1280, height: 720),
                              cropOrigin: .zero, fpsExpression: "30000/1001") {
    check(zf.contains("fps=30000/1001"), "the exact frame rate is passed through", zf)
    check(zf.contains("s=1280x720"), "output size matches the input size")
    check(zf.contains("d=1"), "one output frame per input frame")
    check(zf.contains("in_time"), "the ramp is driven by presentation time")
}

// Targets are stored full-frame, so a crop has to shift them.
if let zf = FFmpeg.zoomFilter(shots: [shot], frame: CGSize(width: 640, height: 480),
                              cropOrigin: CGPoint(x: 100, y: 50),
                              fpsExpression: "30") {
    // target 930,530 - crop origin 100,50 = 830,480; centre of a 640x480 frame is 320,240.
    check(zf.contains("510.0000"), "x target is offset by the crop origin", zf)
    check(zf.contains("240.0000"), "y target is offset by the crop origin", zf)
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

// MARK: - Zoom encodes

print("\nZoom encodes")

// A clip with a small red marker, so the zoom can be measured rather than eyeballed.
let markerClip = scratch.appendingPathComponent("marker.mov")
_ = try await Shell.run(ffmpeg, [
    "-hide_banner", "-loglevel", "error", "-y",
    "-f", "lavfi", "-i", "color=gray:s=1280x720:r=30", "-t", "3",
    "-vf", "drawbox=900:500:60:60:red@1:t=fill",
    "-c:v", "libx264", "-crf", "18", "-pix_fmt", "yuv420p", markerClip.path,
])
let markerInfo = try await FFmpeg.probe(url: markerClip)
equal(markerInfo.fpsExpression, "30/1", "frame rate is captured verbatim")

/// Bounding box of the red marker in one frame, or nil when it is off screen.
func markerBox(_ url: URL, at time: Double, size: CGSize) async throws -> CGRect? {
    let result = try await Shell.run(ffmpeg, [
        "-hide_banner", "-loglevel", "error",
        "-ss", String(format: "%.3f", time), "-i", url.path, "-frames:v", "1",
        "-f", "rawvideo", "-pix_fmt", "rgb24", "-",
    ])
    let bytes = [UInt8](result.stdout)
    let w = Int(size.width), h = Int(size.height)
    guard bytes.count >= w * h * 3 else { return nil }
    var minX = w, maxX = -1, minY = h, maxY = -1
    for y in stride(from: 0, to: h, by: 2) {
        for x in stride(from: 0, to: w, by: 2) {
            let i = (y * w + x) * 3
            if bytes[i] > 150, bytes[i + 1] < 90, bytes[i + 2] < 90 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
    }
    guard maxX >= 0 else { return nil }
    return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
}

var zoomSettings = ExportSettings()
zoomSettings.suffix = "-zoom"
let zoomShot = ZoomShot(start: 0.5, hold: 1.0, level: 2, target: CGPoint(x: 930, y: 530))
let zoomOut = FFmpeg.outputURL(for: markerClip, settings: zoomSettings)
try await FFmpeg.export(input: markerClip, output: zoomOut, info: markerInfo,
                        crop: markerInfo.fullFrame, zoomShots: [zoomShot],
                        settings: zoomSettings) { _ in }

let zoomInfo = try await FFmpeg.probe(url: zoomOut)
equal(zoomInfo.width, 1280, "zoom keeps the frame size")
equal(zoomInfo.height, 720, "zoom keeps the frame height")
check(abs(zoomInfo.duration - markerInfo.duration) < 0.1, "zoom preserves duration",
      "\(markerInfo.duration) -> \(zoomInfo.duration)")

let frameSize = CGSize(width: 1280, height: 720)
let before = try await markerBox(zoomOut, at: 0.2, size: frameSize)
let held = try await markerBox(zoomOut, at: 1.5, size: frameSize)
let after = try await markerBox(zoomOut, at: 2.8, size: frameSize)

if let before, let held, let after {
    check(abs(before.width - 58) < 6, "before the shot the frame is untouched", "\(before)")
    check(held.width > before.width * 1.8,
          "the marker is magnified during the hold",
          String(format: "%.0f -> %.0f px", before.width, held.width))
    check(abs(held.midX - 640) < 12 && abs(held.midY - 360) < 12,
          "the target sits in the centre of frame while held",
          String(format: "centre (%.0f, %.0f)", held.midX, held.midY))
    check(abs(after.width - before.width) < 6, "the shot eases back out to normal",
          "\(after)")
} else {
    check(false, "marker was visible before, during and after the zoom")
}

// The hold must be perfectly still — any wobble here is visible on playback.
let holdA = try await markerBox(zoomOut, at: 1.1, size: frameSize)
let holdB = try await markerBox(zoomOut, at: 1.9, size: frameSize)
if let holdA, let holdB {
    check(abs(holdA.midX - holdB.midX) < 2 && abs(holdA.midY - holdB.midY) < 2,
          "the view does not drift during the hold",
          "\(holdA.origin) vs \(holdB.origin)")
    check(abs(holdA.width - holdB.width) < 2, "the zoom level is steady during the hold")
}

// The ease must be monotonic — no stutter or overshoot on the way in.
var sizes: [CGFloat] = []
for step in 0...5 {
    let t = 0.5 + Double(step) * 0.1
    if let boxAtT = try await markerBox(zoomOut, at: t, size: frameSize) { sizes.append(boxAtT.width) }
}
check(sizes.count >= 5 && zip(sizes, sizes.dropFirst()).allSatisfy { $1 >= $0 - 1 },
      "the zoom grows monotonically through the ease-in",
      sizes.map { String(format: "%.0f", $0) }.joined(separator: " → "))

// Zoom composed with a crop: the target must still land centre-frame, in *cropped*
// coordinates. Crop chosen so the target is far enough from the edges to actually centre.
var comboSettings = ExportSettings()
comboSettings.suffix = "-zoomcrop"
let comboOut = FFmpeg.outputURL(for: markerClip, settings: comboSettings)
let comboCrop = CGRect(x: 400, y: 250, width: 800, height: 440)
try await FFmpeg.export(input: markerClip, output: comboOut, info: markerInfo,
                        crop: comboCrop, zoomShots: [zoomShot],
                        settings: comboSettings) { _ in }
let comboInfo = try await FFmpeg.probe(url: comboOut)
equal(comboInfo.width, 800, "crop still applies with a zoom")
let comboSize = CGSize(width: 800, height: 440)
if let boxed = try await markerBox(comboOut, at: 1.5, size: comboSize) {
    check(abs(boxed.midX - 400) < 14 && abs(boxed.midY - 220) < 14,
          "the target centres correctly inside a cropped frame",
          String(format: "centre (%.0f, %.0f) want (400, 220)", boxed.midX, boxed.midY))
}

// A target near the edge cannot be centred without showing outside the frame, so the
// view clamps to the edge instead. The corners must stay real picture, never black bars.
var edgeSettings = ExportSettings()
edgeSettings.suffix = "-zoomedge"
let edgeOut = FFmpeg.outputURL(for: markerClip, settings: edgeSettings)
let edgeShot = ZoomShot(start: 0.5, hold: 1.0, level: 3, target: CGPoint(x: 1270, y: 715))
try await FFmpeg.export(input: markerClip, output: edgeOut, info: markerInfo,
                        crop: markerInfo.fullFrame, zoomShots: [edgeShot],
                        settings: edgeSettings) { _ in }
var cornersAreLive = true
for (cx, cy) in [(4, 4), (1270, 4), (4, 710), (1270, 710)] {
    let corner = try await pixel(edgeOut, x: cx, y: cy, at: 1.5)
    // Source background is mid-grey; a letterboxed edge would read near-black.
    if corner.0 < 40 && corner.1 < 40 && corner.2 < 40 { cornersAreLive = false }
}
check(cornersAreLive, "a zoom near the edge clamps inside the frame instead of showing bars")

// Two shots in one clip, plus audio, through the full pipeline.
var multiSettings = ExportSettings()
multiSettings.suffix = "-multizoom"
let multiOut = FFmpeg.outputURL(for: landscape, settings: multiSettings)
let shots = [
    ZoomShot(start: 0.2, hold: 0.5, level: 2, target: CGPoint(x: 400, y: 300)),
    ZoomShot(start: 1.6, hold: 0.5, level: 3, target: CGPoint(x: 900, y: 400)),
]
try await FFmpeg.export(input: landscape, output: multiOut, info: info,
                        crop: info.fullFrame, zoomShots: shots,
                        settings: multiSettings) { _ in }
let multiInfo = try await FFmpeg.probe(url: multiOut)
equal(multiInfo.audioCodec, "aac", "audio survives a zoom render")
check(abs(multiInfo.duration - info.duration) < 0.15, "two zooms preserve duration",
      "\(info.duration) -> \(multiInfo.duration)")

// Blur + crop + zoom together.
var allSettings = ExportSettings()
allSettings.blurStyle = .black
allSettings.suffix = "-everything"
let allOut = FFmpeg.outputURL(for: markerClip, settings: allSettings)
try await FFmpeg.export(input: markerClip, output: allOut, info: markerInfo,
                        crop: CGRect(x: 100, y: 50, width: 1000, height: 600),
                        regions: [CGRect(x: 200, y: 200, width: 100, height: 100)],
                        zoomShots: [zoomShot], settings: allSettings) { _ in }
equal(try await FFmpeg.probe(url: allOut).width, 1000, "blur, crop and zoom compose")

// MARK: - GIF and WebP

print("\nGIF and WebP arguments")

var gif = ExportSettings()
gif.format = .gif
gif.suffix = "-gif"

equal(FFmpeg.outputURL(for: landscape, settings: gif).pathExtension, "gif",
      "GIF export writes a .gif")
var webp = ExportSettings()
webp.format = .webp
webp.suffix = "-webp"
equal(FFmpeg.outputURL(for: landscape, settings: webp).pathExtension, "webp",
      "WebP export writes a .webp")

let gifTarget = scratch.appendingPathComponent("args.gif")
let gifCommands = FFmpeg.exportCommands(input: landscape, output: gifTarget, info: info,
                                        crop: info.fullFrame, settings: gif)
equal(gifCommands.count, 2, "GIF runs a palette pass and an encode pass")
equal(FFmpeg.exportCommands(input: landscape, output: scratch.appendingPathComponent("a.mp4"),
                            info: info, crop: info.fullFrame, settings: ExportSettings()).count, 1,
      "MP4 runs a single command")

let paletteArgs = gifCommands[0]
check(paletteArgs.contains { $0.contains("palettegen=max_colors=256:stats_mode=diff") },
      "the palette pass builds a diff-weighted palette", paletteArgs.joined(separator: " "))
check(paletteArgs.contains { $0.contains("fps=15") }, "the palette pass thins the frame rate")
equal(paletteArgs.last ?? "", FFmpeg.paletteURL(for: gifTarget).path,
      "the palette pass writes the palette")

let gifArgs = gifCommands[1]
check(gifArgs.contains(FFmpeg.paletteURL(for: gifTarget).path),
      "the encode pass reads the palette back in")
check(gifArgs.contains { $0.contains("paletteuse=dither=bayer:bayer_scale=5:diff_mode=rectangle") },
      "the encode pass maps frames through the palette", gifArgs.joined(separator: " "))
check(gifArgs.contains("[gif]"), "the palette graph output is mapped explicitly")
check(gifArgs.contains("-an"), "GIF drops audio")
if let loopIndex = gifArgs.firstIndex(of: "-loop") {
    equal(gifArgs[loopIndex + 1], "0", "looping GIF passes -loop 0")
} else {
    check(false, "GIF sets a loop count")
}
check(!gifArgs.contains("-movflags"), "GIF skips the MP4-only muxer flags")

// The two formats disagree about how to spell "play once".
var once = gif
once.loopForever = false
let onceArgs = FFmpeg.exportArguments(input: landscape, output: gifTarget, info: info,
                                      crop: info.fullFrame, settings: once,
                                      palette: FFmpeg.paletteURL(for: gifTarget))
if let i = onceArgs.firstIndex(of: "-loop") { equal(onceArgs[i + 1], "-1", "a one-shot GIF passes -loop -1") }
var webpOnce = webp
webpOnce.loopForever = false
let webpOnceArgs = FFmpeg.exportArguments(input: landscape, output: scratch.appendingPathComponent("a.webp"),
                                          info: info, crop: info.fullFrame, settings: webpOnce)
if let i = webpOnceArgs.firstIndex(of: "-loop") { equal(webpOnceArgs[i + 1], "1", "a one-shot WebP passes -loop 1") }

let webpArgs = FFmpeg.exportArguments(input: landscape, output: scratch.appendingPathComponent("a.webp"),
                                      info: info, crop: info.fullFrame, settings: webp)
check(webpArgs.contains("libwebp"), "WebP uses the libwebp encoder")
check(webpArgs.contains("-compression_level"), "WebP asks libwebp for its best compression")
if let i = webpArgs.firstIndex(of: "-quality") { equal(webpArgs[i + 1], "70", "WebP quality comes off the slider") }
check(webpArgs.contains("-an"), "WebP drops audio")
var lossless = webp
lossless.webpLossless = true
let losslessArgs = FFmpeg.exportArguments(input: landscape, output: scratch.appendingPathComponent("a.webp"),
                                          info: info, crop: info.fullFrame, settings: lossless)
if let i = losslessArgs.firstIndex(of: "-pix_fmt") {
    equal(losslessArgs[i + 1], "bgra", "lossless WebP keeps RGB rather than going through yuv420p")
}
if let i = losslessArgs.firstIndex(of: "-lossless") {
    equal(losslessArgs[i + 1], "1", "lossless WebP sets -lossless 1")
} else {
    check(false, "lossless WebP sets -lossless")
}

// Frame rate: never above the source, and never on MP4.
var sourceRate = gif
sourceRate.frameRate = .source
check(!FFmpeg.exportCommands(input: landscape, output: gifTarget, info: info,
                             crop: info.fullFrame, settings: sourceRate)
        .joined().contains { $0.contains("fps=") },
      "the source frame rate adds no fps filter")
var slowClip = info
slowClip.fps = 12
var fastRate = gif
fastRate.frameRate = .fps24
check(!FFmpeg.exportCommands(input: landscape, output: gifTarget, info: slowClip,
                             crop: slowClip.fullFrame, settings: fastRate)
        .joined().contains { $0.contains("fps=24") },
      "a 12 fps source is never padded up to 24")
var mp4Rate = ExportSettings()
mp4Rate.frameRate = .fps10
check(!FFmpeg.exportArguments(input: landscape, output: scratch.appendingPathComponent("a.mp4"),
                              info: info, crop: info.fullFrame, settings: mp4Rate)
        .contains { $0.contains("fps=") },
      "the animation frame rate does not leak into MP4 exports")

// The palette graph has to splice onto whatever the blur left behind.
let plainGraph = FFmpeg.exportArguments(input: landscape, output: gifTarget, info: info,
                                        crop: info.fullFrame, settings: sourceRate,
                                        palette: FFmpeg.paletteURL(for: gifTarget))
check(plainGraph.contains("[0:v][1:v]paletteuse=dither=bayer:bayer_scale=5:diff_mode=rectangle[gif]"),
      "an untouched frame feeds paletteuse directly", plainGraph.joined(separator: " "))
let croppedGraph = FFmpeg.exportArguments(input: landscape, output: gifTarget, info: info,
                                          crop: CGRect(x: 0, y: 0, width: 640, height: 360),
                                          settings: sourceRate,
                                          palette: FFmpeg.paletteURL(for: gifTarget))
check(croppedGraph.contains { $0.hasPrefix("[0:v]crop=640:360:0:0[pre];[pre][1:v]paletteuse") },
      "a simple chain is relabelled before paletteuse", croppedGraph.joined(separator: " "))
let blurredGraph = FFmpeg.exportArguments(input: landscape, output: gifTarget, info: info,
                                          crop: info.fullFrame, regions: [r1],
                                          settings: sourceRate,
                                          palette: FFmpeg.paletteURL(for: gifTarget))
check(blurredGraph.contains { $0.contains("[vout][1:v]paletteuse") },
      "a blur graph feeds its output pad into paletteuse", blurredGraph.joined(separator: " "))

print("\nGIF encodes")

/// Number of frames actually stored in a file.
func frameCount(_ url: URL) async throws -> Int {
    guard let ffprobe = FFmpeg.ffprobePath else { return 0 }
    let result = try await Shell.run(ffprobe, [
        "-v", "error", "-select_streams", "v:0", "-count_packets",
        "-show_entries", "stream=nb_read_packets", "-of", "csv=p=0", url.path,
    ])
    return Int(result.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
}

var gifProgress: [Double] = []
let gifOut = FFmpeg.outputURL(for: landscape, settings: gif)
try await FFmpeg.export(input: landscape, output: gifOut, info: info,
                        crop: info.fullFrame, settings: gif) { gifProgress.append($0) }

let gifInfo = try await FFmpeg.probe(url: gifOut)
equal(gifInfo.videoCodec, "gif", "output really is a GIF")
equal(gifInfo.width, 1280, "GIF keeps the frame size")
check(gifInfo.audioCodec == nil, "GIF has no audio track")
let gifFrames = try await frameCount(gifOut)
check(abs(gifFrames - 45) <= 3, "3s at 15 fps lands on ~45 frames", "got \(gifFrames)")
check(gifProgress.count > 1 && gifProgress == gifProgress.sorted(),
      "progress climbs across both passes", "\(gifProgress.count) updates")
check(!FileManager.default.fileExists(atPath: FFmpeg.paletteURL(for: gifOut).path),
      "the palette is cleaned up afterwards")

// A smaller palette and a lower frame rate must actually produce a smaller file.
var lean = gif
lean.gifColors = .minimal
lean.frameRate = .fps10
lean.sizeLimit = .vga
lean.suffix = "-gif-lean"
let leanOut = FFmpeg.outputURL(for: landscape, settings: lean)
try await FFmpeg.export(input: landscape, output: leanOut, info: info,
                        crop: info.fullFrame, settings: lean) { _ in }
let leanInfo = try await FFmpeg.probe(url: leanOut)
equal(leanInfo.width, 640, "the size cap applies to GIFs")
func fileSize(_ url: URL) -> Int {
    let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
    return (attributes?[.size] as? NSNumber)?.intValue ?? 0
}
check(fileSize(leanOut) < fileSize(gifOut),
      "fewer colours, frames and pixels make a smaller file",
      "\(fileSize(gifOut)) -> \(fileSize(leanOut)) bytes")

// Crop, blur and zoom have to survive the palette detour intact.
var richGif = gif
richGif.blurStyle = .black
richGif.suffix = "-gif-everything"
let richOut = FFmpeg.outputURL(for: markerClip, settings: richGif)
try await FFmpeg.export(input: markerClip, output: richOut, info: markerInfo,
                        crop: CGRect(x: 100, y: 50, width: 640, height: 480),
                        regions: [CGRect(x: 200, y: 100, width: 160, height: 120)],
                        zoomShots: [zoomShot], settings: richGif) { _ in }
let richInfo = try await FFmpeg.probe(url: richOut)
equal(richInfo.width, 640, "crop applies to a GIF")
let gifBox = try await pixel(richOut, x: 150, y: 100, at: 0.2)
check(gifBox.0 < 40 && gifBox.1 < 40 && gifBox.2 < 40,
      "the blur box lands in the right place in a GIF", "rgb\(gifBox)")

var gifOnce = gif
gifOnce.loopForever = false
gifOnce.suffix = "-gif-once"
let gifOnceOut = FFmpeg.outputURL(for: landscape, settings: gifOnce)
try await FFmpeg.export(input: landscape, output: gifOnceOut, info: info,
                        crop: info.fullFrame, settings: gifOnce) { _ in }
check(try await frameCount(gifOnceOut) > 1, "a play-once GIF is still a valid animation")

// A failed second pass must report the error and take the palette with it.
var doomed = gif
doomed.suffix = "-doomed"
let doomedOut = URL(fileURLWithPath: "/no-such-directory-xyz/out.gif")
do {
    try await FFmpeg.export(input: landscape, output: doomedOut, info: info,
                            crop: info.fullFrame, settings: doomed) { _ in }
    check(false, "a failing GIF encode reports an error")
} catch {
    check(!error.localizedDescription.isEmpty, "a failing GIF encode reports an error")
    check(!FileManager.default.fileExists(atPath: FFmpeg.paletteURL(for: doomedOut).path),
          "a failed GIF encode leaves no palette behind")
}

print("\nWebP encodes")
if await FFmpeg.supportsWebP() {
    let webpOut = FFmpeg.outputURL(for: landscape, settings: webp)
    var webpProgress: [Double] = []
    try await FFmpeg.export(input: landscape, output: webpOut, info: info,
                            crop: CGRect(x: 0, y: 0, width: 640, height: 360),
                            settings: webp) { webpProgress.append($0) }
    let webpInfo = try await FFmpeg.probe(url: webpOut)
    equal(webpInfo.width, 640, "WebP honours the crop")
    check(webpInfo.audioCodec == nil, "WebP has no audio track")
    let webpFrames = try await frameCount(webpOut)
    check(webpFrames > 1, "WebP output is animated, not a single frame", "\(webpFrames) frames")
    check(webpProgress.last == 1.0, "WebP progress finishes at 100%")

    // Lossless feeds libwebp a different pixel format; make sure it accepts it.
    var losslessOut = webp
    losslessOut.webpLossless = true
    losslessOut.suffix = "-webp-lossless"
    let losslessFile = FFmpeg.outputURL(for: landscape, settings: losslessOut)
    try await FFmpeg.export(input: landscape, output: losslessFile, info: info,
                            crop: CGRect(x: 0, y: 0, width: 640, height: 360),
                            settings: losslessOut) { _ in }
    check(try await frameCount(losslessFile) > 1, "lossless WebP encodes and animates")
    check(fileSize(losslessFile) > fileSize(webpOut), "lossless WebP is the bigger one",
          "lossy \(fileSize(webpOut)) vs lossless \(fileSize(losslessFile)) bytes")

    // Play-once is a different muxer value on both formats, and easy to get backwards.
    var webpOnceOut = webp
    webpOnceOut.loopForever = false
    webpOnceOut.suffix = "-webp-once"
    let webpOnceFile = FFmpeg.outputURL(for: landscape, settings: webpOnceOut)
    try await FFmpeg.export(input: landscape, output: webpOnceFile, info: info,
                            crop: CGRect(x: 0, y: 0, width: 640, height: 360),
                            settings: webpOnceOut) { _ in }
    check(try await frameCount(webpOnceFile) > 1, "a play-once WebP is still a valid animation")

    // The whole point of the format: the same loop, much smaller.
    var matched = gif
    matched.suffix = "-gif-match"
    let matchOut = FFmpeg.outputURL(for: landscape, settings: matched)
    try await FFmpeg.export(input: landscape, output: matchOut, info: info,
                            crop: CGRect(x: 0, y: 0, width: 640, height: 360),
                            settings: matched) { _ in }
    check(fileSize(webpOut) < fileSize(matchOut),
          "WebP beats the equivalent GIF on size",
          "gif \(fileSize(matchOut)) vs webp \(fileSize(webpOut)) bytes")
} else {
    // Homebrew's stock ffmpeg has libwebp; plenty of custom builds do not.
    print("  skip this ffmpeg has no libwebp — checking the error instead")
    do {
        try await FFmpeg.export(input: landscape, output: scratch.appendingPathComponent("nope.webp"),
                                info: info, crop: info.fullFrame, settings: webp) { _ in }
        check(false, "a WebP export without libwebp fails up front")
    } catch {
        check(error.localizedDescription.contains("libwebp"),
              "a WebP export without libwebp explains itself",
              error.localizedDescription)
    }
}

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

// MARK: - Filter detection

print("\nFilter detection")

let legend = """
Filters:
  T.. = Timeline support
  .S. = Slice threading
  A = Audio input/output
  ------

"""
let threeFlags = FFmpeg.filterNames(in: legend + """
 ..C subtitles         V->V       Render text subtitles onto input video using the libass library.
 .S. zscale            V->V       Apply resizing, colorspace and bit depth conversion.
""")
equal(threeFlags, ["subtitles", "zscale"], "older three-flag rows are read, the legend is not")
let twoFlags = FFmpeg.filterNames(in: legend + """
 .. subtitles         V->V       Render text subtitles onto input video using the libass library.
 .S zscale            V->V       Apply resizing, colorspace and bit depth conversion.
""")
equal(twoFlags, ["subtitles", "zscale"], "ffmpeg 9's two-flag rows are read too")
// Every build has scale; an empty set here means the listing format moved again.
check(await FFmpeg.filters().contains("scale"), "the installed ffmpeg's filter list parses")

// MARK: - HDR tone mapping

print("\nHDR tone mapping")

check(!info.isHDR, "the plain fixture is SDR", info.colorTransfer ?? "no transfer tag")

// The same clip as an HLG source, the way iPhone footage and HDR screen recordings arrive.
var hlg: URL?
do {
    let url = scratch.appendingPathComponent("hlg.mov")
    let result = try await Shell.run(ffmpeg, [
        "-hide_banner", "-loglevel", "error", "-y",
        "-f", "lavfi", "-i", "testsrc2=size=640x360:rate=30", "-t", "2",
        "-c:v", "libx264", "-pix_fmt", "yuv420p",
        // The container-level flags are what older ffmpeg honoured; ffmpeg 9's libx264
        // ignores them and writes an untagged stream, which made this fixture silently
        // SDR and skipped every tone-mapping check below. Passing the tags through to
        // x264 itself writes them into the bitstream. Both are sent so the fixture is
        // correct whichever build is installed.
        "-color_trc", "arib-std-b67", "-colorspace", "bt2020nc", "-color_primaries", "bt2020",
        "-x264-params", "transfer=arib-std-b67:colorprim=bt2020:colormatrix=bt2020nc",
        url.path,
    ])
    if result.status == 0 { hlg = url }
}
check(hlg != nil, "created an HLG-tagged clip")

var hlgInfo: MediaInfo?
if let hlg {
    let probed = try await FFmpeg.probe(url: hlg)
    check(probed.isHDR, "an HLG source is detected as HDR", probed.colorTransfer ?? "nil")
    equal(probed.hdrLabel, "HLG", "HLG is named for the UI")
    if probed.isHDR { hlgInfo = probed }
}

// Detection and the head of the graph, independent of what ffmpeg happened to tag.
var hdrInfo = info
hdrInfo.colorTransfer = "arib-std-b67"
var pqInfo = info
pqInfo.colorTransfer = "smpte2084"
check(hdrInfo.isHDR, "HLG counts as HDR")
check(pqInfo.isHDR, "PQ counts as HDR")
equal(pqInfo.hdrLabel, "HDR10 (PQ)", "PQ is named for the UI")

var toneSettings = ExportSettings()
check(FFmpeg.videoHead(info: info, settings: toneSettings).isEmpty, "an SDR clip gets no tone map")
check(!FFmpeg.videoHead(info: hdrInfo, settings: toneSettings).isEmpty, "an HDR clip gets one")
toneSettings.toneMapHDR = false
check(FFmpeg.videoHead(info: hdrInfo, settings: toneSettings).isEmpty,
      "turning the toggle off removes it")

if let headOnly = FFmpeg.filterGraph(head: ["zscale=t=linear"], regions: [],
                                     style: .blur, strength: 20, tail: []) {
    check(!headOnly.isComplex, "a head with no regions stays a simple -vf chain")
    equal(headOnly.spec, "zscale=t=linear", "the head alone is the whole chain")
} else {
    check(false, "a head alone still produces a filter chain")
}

if let headed = FFmpeg.filterGraph(head: ["zscale=t=linear"], regions: [r1],
                                   style: .blur, strength: 20, tail: []) {
    check(headed.spec.hasPrefix("[0:v]zscale=t=linear,split=2"),
          "the head runs once, before the split", headed.spec)
}

if let headedBoxes = FFmpeg.filterGraph(head: ["zscale=t=linear"], regions: [r1],
                                        style: .black, strength: 20, tail: ["crop=2:2:0:0"]) {
    check(headedBoxes.spec.hasPrefix("zscale=t=linear,drawbox="),
          "black boxes keep the head in front", headedBoxes.spec)
}

let hdrArgs = FFmpeg.exportArguments(
    input: landscape, output: scratch.appendingPathComponent("hdr.mp4"),
    info: hdrInfo, crop: hdrInfo.fullFrame, settings: ExportSettings())
check(hdrArgs.joined(separator: " ").contains("tonemap="),
      "an HDR export tone-maps in the filter chain")
if let index = hdrArgs.firstIndex(of: "-color_trc") {
    equal(hdrArgs[index + 1], "bt709", "the tone-mapped output is tagged Rec.709")
} else {
    check(false, "the tone-mapped output is tagged Rec.709")
}

let sdrArgs = FFmpeg.exportArguments(
    input: landscape, output: scratch.appendingPathComponent("sdr.mp4"),
    info: info, crop: info.fullFrame, settings: ExportSettings())
check(!sdrArgs.contains("-color_trc"), "an SDR export is not re-tagged")
check(!sdrArgs.joined(separator: " ").contains("tonemap="), "an SDR export has no tone map")

// Preview and export share the graph builder, so the preview must tone-map too.
let canToneMap = await FFmpeg.supportsToneMapping()
if let hlg, let hlgInfo, canToneMap {
    let mapped = try? await FFmpeg.thumbnail(url: hlg, at: 0.5, duration: hlgInfo.duration,
                                             toneMap: true)
    check(mapped != nil, "the preview can tone-map a frame")

    let hlgOut = scratch.appendingPathComponent("hlg-converted.mp4")
    try await FFmpeg.export(input: hlg, output: hlgOut, info: hlgInfo,
                            crop: hlgInfo.fullFrame, settings: ExportSettings()) { _ in }
    let hlgOutInfo = try await FFmpeg.probe(url: hlgOut)
    equal(hlgOutInfo.colorTransfer, "bt709", "the exported file says it is Rec.709")
    check(!hlgOutInfo.isHDR, "the exported file is no longer flagged HDR")

    // With the toggle off nothing is relabelled — the export is left as ffmpeg found it.
    var untouched = ExportSettings()
    untouched.toneMapHDR = false
    let asIsOut = scratch.appendingPathComponent("hlg-as-is.mp4")
    try await FFmpeg.export(input: hlg, output: asIsOut, info: hlgInfo,
                            crop: hlgInfo.fullFrame, settings: untouched) { _ in }
    let asIsInfo = try await FFmpeg.probe(url: asIsOut)
    check(asIsInfo.colorTransfer != "bt709", "turning the toggle off does not relabel Rec.709",
          asIsInfo.colorTransfer ?? "nil")
} else if hlg != nil {
    print("  --   tone-map encodes skipped (no zscale, or the fixture is not tagged HLG)")
}

// MARK: - Loudness normalisation

print("\nLoudness")

var loud = ExportSettings()
loud.audio = .normalised
check(FFmpeg.needsLoudnessPass(info: info, settings: loud), "MP4 with audio needs a measuring pass")

var mute = info
mute.audioCodec = nil
check(!FFmpeg.needsLoudnessPass(info: mute, settings: loud), "a silent clip needs no pass")

var gifLoud = loud
gifLoud.format = .gif
check(!FFmpeg.needsLoudnessPass(info: info, settings: gifLoud), "GIF has no audio to normalise")

var plainAudio = ExportSettings()
plainAudio.audio = .aac
check(!FFmpeg.needsLoudnessPass(info: info, settings: plainAudio), "plain AAC needs no pass")

let loudTarget = scratch.appendingPathComponent("loud.mp4")
let loudCommands = FFmpeg.exportCommands(input: landscape, output: loudTarget, info: info,
                                         crop: info.fullFrame, settings: loud)
equal(loudCommands.count, 2, "normalising runs a measuring pass and an encode")
check(loudCommands[0].joined(separator: " ").contains("print_format=json"),
      "the first pass asks for the measurement")
equal(loudCommands[0].last, "-", "the measuring pass writes nothing")
check(loudCommands[0].contains("-vn"), "the measuring pass skips the video")
let encodeText = loudCommands[1].joined(separator: " ")
check(encodeText.contains("loudnorm=I=-14:TP=-1:LRA=11"), "the encode carries the target", encodeText)
check(loudCommands[1].contains("48000"),
      "the output rate is pinned, since loudnorm works at 192 kHz internally")

// A silent clip skips the whole thing rather than measuring nothing.
equal(FFmpeg.exportCommands(input: landscape, output: loudTarget, info: mute,
                            crop: mute.fullFrame, settings: loud).count, 1,
      "a silent clip runs one command")

// Parsing what the measuring pass prints.
let sampleLog = """
[Parsed_loudnorm_0 @ 0x7fd] some other chatter
{
    "input_i" : "-23.45",
    "input_tp" : "-5.20",
    "input_lra" : "7.30",
    "input_thresh" : "-33.61",
    "output_i" : "-14.01",
    "target_offset" : "0.21"
}
"""
if let measured = FFmpeg.parseLoudness(sampleLog) {
    equal(measured.inputI, "-23.45", "reads the integrated loudness")
    equal(measured.targetOffset, "0.21", "reads the target offset")
    check(measured.filterArguments.contains("measured_I=-23.45"),
          "hands the measurement back to the second pass")
    check(measured.filterArguments.contains("linear=true"),
          "asks for a gain match rather than compression")
} else {
    check(false, "parses a loudnorm measurement block")
}

check(FFmpeg.parseLoudness("nothing to see here") == nil, "a log with no measurement is nil")
check(FFmpeg.parseLoudness("{ not json ]") == nil, "a malformed block is nil")

// Digital silence measures as -inf, which ffmpeg will not take back.
let silentLog = """
{
    "input_i" : "-inf",
    "input_tp" : "-inf",
    "input_lra" : "0.00",
    "input_thresh" : "-inf",
    "target_offset" : "0.00"
}
"""
check(FFmpeg.parseLoudness(silentLog) == nil, "an -inf measurement is refused")

// An unmeasured encode still has a usable filter, so the fallback is safe.
let unmeasured = FFmpeg.exportArguments(input: landscape, output: loudTarget, info: info,
                                        crop: info.fullFrame, settings: loud, loudness: nil)
check(unmeasured.joined(separator: " ").contains("loudnorm=I=-14"),
      "an unmeasured encode still normalises")
check(!unmeasured.joined(separator: " ").contains("measured_I"),
      "an unmeasured encode carries no measurements")

// The real thing: a full-scale sine is far too loud, and should come back near target.
func integratedLoudness(_ url: URL) async throws -> Double? {
    let result = try await Shell.run(ffmpeg, [
        "-hide_banner", "-nostdin", "-i", url.path,
        "-af", "loudnorm=\(Loudness.filterTargets):print_format=json",
        "-vn", "-f", "null", "-",
    ])
    guard let measured = FFmpeg.parseLoudness(result.stderrText) else { return nil }
    return Double(measured.inputI)
}

// Small frame so the encode is quick, but comfortably longer than the three seconds
// loudnorm wants before its integrated measurement settles.
let loudSource = try await makeClip("loud-source.mov", size: "320x180", seconds: 6, audio: "aac")
let loudSourceInfo = try await FFmpeg.probe(url: loudSource)
let loudOut = scratch.appendingPathComponent("loud-converted.mp4")
try await FFmpeg.export(input: loudSource, output: loudOut, info: loudSourceInfo,
                        crop: loudSourceInfo.fullFrame, settings: loud) { _ in }
check(FileManager.default.fileExists(atPath: loudOut.path), "the normalised export produced a file")

let loudOutInfo = try await FFmpeg.probe(url: loudOut)
equal(loudOutInfo.audioCodec, "aac", "the normalised output still carries an AAC track")
check(abs(loudOutInfo.duration - loudSourceInfo.duration) < 0.25,
      "normalising does not change the duration",
      "\(loudOutInfo.duration) vs \(loudSourceInfo.duration)")

if let before = try await integratedLoudness(loudSource),
   let after = try await integratedLoudness(loudOut) {
    check(abs(after + 14) < abs(before + 14), "normalising moves loudness toward -14 LUFS",
          "before \(before), after \(after)")
    check(abs(after + 14) < 2.0, "the normalised output lands within 2 LU of the target",
          "\(after) LUFS")
} else {
    check(false, "could measure the loudness either side of the export")
}

// MARK: - Subtitles

print("\nSubtitles")

// A path full of everything the filter parsers treat as special.
let awkward = URL(fileURLWithPath: "/tmp/a:b,c;d'e\\f/My Captions.SRT")
let stagedAwkward = FFmpeg.stagedSubtitlesURL(for: awkward)
let hostile = Set(":,;'\\[]")
check(!stagedAwkward.path.contains(where: { hostile.contains($0) }),
      "the staged path carries nothing the filter parser would choke on", stagedAwkward.path)
equal(stagedAwkward.pathExtension, "srt", "the extension is normalised to lower case")
check(stagedAwkward.lastPathComponent.contains("MyCaptions"),
      "the staged name still hints at the original", stagedAwkward.lastPathComponent)
equal(FFmpeg.stagedSubtitlesURL(for: awkward), stagedAwkward,
      "the staged path is the same every time, so the shown command is the one that runs")
check(FFmpeg.stagedSubtitlesURL(for: URL(fileURLWithPath: "/tmp/a-b,c;d'e\\f/My Captions.SRT"))
        != stagedAwkward,
      "two different sources never share a staged copy")

// A name with nothing safe left in it still produces a usable path.
let unnameable = FFmpeg.stagedSubtitlesURL(for: URL(fileURLWithPath: "/tmp/:::.vtt"))
check(unnameable.lastPathComponent.hasPrefix("yamvideo-subs-"), "an unnameable file still stages",
      unnameable.lastPathComponent)
equal(unnameable.pathExtension, "vtt", "a VTT keeps its extension")

// Staging itself.
let srt = scratch.appendingPathComponent("captions.srt")
try """
1
00:00:00,200 --> 00:00:02,800
BURNED IN

""".write(to: srt, atomically: true, encoding: .utf8)

let staged = try FFmpeg.stageSubtitles(srt)
check(FileManager.default.fileExists(atPath: staged.path), "staging copies the file")
equal(try String(contentsOf: staged, encoding: .utf8),
      try String(contentsOf: srt, encoding: .utf8), "the staged copy matches the original")
equal(try FFmpeg.stageSubtitles(srt), staged, "staging again returns the same path")

do {
    _ = try FFmpeg.stageSubtitles(scratch.appendingPathComponent("not-there.srt"))
    check(false, "staging a missing file reports an error")
} catch {
    check(error.localizedDescription.contains("no longer there"),
          "staging a missing file reports an error", error.localizedDescription)
}

// The filter itself.
var subSettings = ExportSettings()
let bottomFilter = FFmpeg.subtitlesFilter(staged: staged, forceStyle: subSettings.subtitleForceStyle)
check(bottomFilter.hasPrefix("subtitles=\(staged.path):force_style='"),
      "the filter names the staged file", bottomFilter)
check(bottomFilter.hasSuffix("'"), "the style is quoted, or its commas would end the filter")
check(bottomFilter.contains("MarginV=35"), "bottom placement uses the low margin")

subSettings.subtitlePlacement = .safeArea
check(FFmpeg.subtitlesFilter(staged: staged, forceStyle: subSettings.subtitleForceStyle)
        .contains("MarginV=90"),
      "the safe area lifts captions clear of the platform UI")

subSettings.subtitleSize = .large
check(subSettings.subtitleForceStyle.contains("FontSize=26"), "size feeds through to the style")

// Ordering: captions are burned after everything that would otherwise move them.
var orderSettings = ExportSettings()
orderSettings.sizeLimit = .small
let orderArgs = FFmpeg.exportArguments(
    input: landscape, output: scratch.appendingPathComponent("subs.mp4"),
    info: info, crop: CGRect(x: 0, y: 0, width: 640, height: 360),
    zoomShots: [ZoomShot(start: 0.2, hold: 0.5, level: 2, target: CGPoint(x: 320, y: 180))],
    settings: orderSettings, subtitles: srt)
if let index = orderArgs.firstIndex(of: "-vf") {
    let chain = orderArgs[index + 1]
    check(chain.contains("subtitles="), "the chain burns the captions in", chain)
    if let subs = chain.range(of: "subtitles="), let scale = chain.range(of: "scale=") {
        check(subs.lowerBound > scale.lowerBound, "captions come after the scale", chain)
    }
    if let subs = chain.range(of: "subtitles="), let zoom = chain.range(of: "zoompan=") {
        check(subs.lowerBound > zoom.lowerBound, "captions come after the zoom", chain)
    }
    if let subs = chain.range(of: "subtitles="), let crop = chain.range(of: "crop=") {
        check(subs.lowerBound > crop.lowerBound, "captions come after the crop", chain)
    }
} else {
    check(false, "an export with captions has a filter chain")
}

check(!FFmpeg.exportArguments(input: landscape, output: scratch.appendingPathComponent("nosubs.mp4"),
                              info: info, crop: info.fullFrame, settings: ExportSettings())
        .joined(separator: " ").contains("subtitles="),
      "no subtitle file means no subtitle filter")

// Both GIF passes have to see the same frames, captions included.
var gifSubs = ExportSettings()
gifSubs.format = .gif
let gifSubCommands = FFmpeg.exportCommands(
    input: landscape, output: scratch.appendingPathComponent("subs.gif"), info: info,
    crop: info.fullFrame, settings: gifSubs, subtitles: srt)
equal(gifSubCommands.count, 2, "a captioned GIF still runs the palette pass and the encode")
check(gifSubCommands[0].joined(separator: " ").contains("subtitles="),
      "the palette pass sees the captions")
check(gifSubCommands[1].joined(separator: " ").contains("subtitles="),
      "the encode sees them too")

// Real rendering, if this ffmpeg can do it at all.
let canBurn = await FFmpeg.supportsSubtitles()
if canBurn {
    /// Raw luma for a band of one already-rendered frame.
    func bandLuma(_ url: URL, y: Int, height: Int, width: Int) async throws -> [UInt8] {
        let result = try await Shell.run(ffmpeg, [
            "-hide_banner", "-loglevel", "error",
            "-i", url.path, "-frames:v", "1",
            "-vf", "crop=\(width):\(height):0:\(y)",
            "-f", "rawvideo", "-pix_fmt", "gray", "-",
        ])
        return [UInt8](result.stdout)
    }

    func meanDifference(_ a: [UInt8], _ b: [UInt8]) -> Double? {
        guard a.count == b.count, !a.isEmpty else { return nil }
        var total = 0
        for index in a.indices { total += abs(Int(a[index]) - Int(b[index])) }
        return Double(total) / Double(a.count)
    }

    // Three frames from the same source: no captions, captions at the bottom, and
    // captions lifted into the safe area. Thumbnails are lossless PNG, so outside the
    // text the pixels are identical and any difference really is the caption. The cue
    // starts at 0.2 s and the preview seeks to 1.0 s, so this also proves the preview
    // times captions from the clip, not from the seek point.
    let bottomStyle = ExportSettings()
    var liftedStyle = ExportSettings()
    liftedStyle.subtitlePlacement = .safeArea

    let plainPNG = try await FFmpeg.thumbnail(url: landscape, at: 1.0, duration: info.duration)
    let bottomPNG = try await FFmpeg.thumbnail(
        url: landscape, at: 1.0, duration: info.duration,
        subtitles: srt, subtitleStyle: bottomStyle.subtitleForceStyle)
    let liftedPNG = try await FFmpeg.thumbnail(
        url: landscape, at: 1.0, duration: info.duration,
        subtitles: srt, subtitleStyle: liftedStyle.subtitleForceStyle)

    check(plainPNG != bottomPNG, "burning a caption changes the frame")
    check(bottomPNG != liftedPNG, "moving the caption changes the frame")

    let plainFile = scratch.appendingPathComponent("frame-plain.png")
    let bottomFile = scratch.appendingPathComponent("frame-bottom.png")
    let liftedFile = scratch.appendingPathComponent("frame-lifted.png")
    try plainPNG.write(to: plainFile)
    try bottomPNG.write(to: bottomFile)
    try liftedPNG.write(to: liftedFile)

    let frame = try await FFmpeg.probe(url: plainFile)
    let width = frame.width
    let lowBand = (y: frame.height * 3 / 4, height: frame.height / 4)
    let topBand = (y: 0, height: frame.height / 4)

    let plainLow = try await bandLuma(plainFile, y: lowBand.y, height: lowBand.height, width: width)
    let bottomLow = try await bandLuma(bottomFile, y: lowBand.y, height: lowBand.height, width: width)
    let plainTop = try await bandLuma(plainFile, y: topBand.y, height: topBand.height, width: width)
    let bottomTop = try await bandLuma(bottomFile, y: topBand.y, height: topBand.height, width: width)

    if let lowDelta = meanDifference(plainLow, bottomLow),
       let topDelta = meanDifference(plainTop, bottomTop) {
        check(lowDelta > 1.0, "the caption really is drawn in the lower quarter",
              "mean delta \(lowDelta)")
        check(lowDelta > topDelta * 5, "and nowhere else in the frame",
              "low \(lowDelta) vs top \(topDelta)")
    } else {
        check(false, "could compare the captioned and plain frames")
    }

    // Lifting the caption should move its ink up the frame. Compare where each caption
    // actually sits rather than whether it touches a fixed band: the seated caption's
    // margin (35/288) ends within a few pixels of the bottom eighth, so whether it
    // reaches that band depends on libass's glyph metrics, not on the placement.
    let plainFull = try await bandLuma(plainFile, y: 0, height: frame.height, width: width)
    func inkRow(_ captioned: URL) async throws -> Double? {
        let pixels = try await bandLuma(captioned, y: 0, height: frame.height, width: width)
        guard pixels.count == plainFull.count, pixels.count == width * frame.height else { return nil }
        var weight = 0.0, moment = 0.0
        for row in 0..<frame.height {
            var delta = 0
            for column in 0..<width {
                let index = row * width + column
                delta += abs(Int(pixels[index]) - Int(plainFull[index]))
            }
            weight += Double(delta)
            moment += Double(delta) * Double(row)
        }
        return weight > 0 ? moment / weight : nil
    }
    if let seated = try await inkRow(bottomFile), let lifted = try await inkRow(liftedFile) {
        check(lifted < seated - Double(frame.height) / 10,
              "the safe area lifts the caption well up the frame",
              "bottom row \(Int(seated)) vs lifted row \(Int(lifted))")
    } else {
        check(false, "could compare the two caption placements")
    }

    // And a real encode end to end.
    var burnSettings = ExportSettings()
    burnSettings.suffix = "-captioned"
    let burnOut = FFmpeg.outputURL(for: landscape, settings: burnSettings)
    try await FFmpeg.export(input: landscape, output: burnOut, info: info,
                            crop: info.fullFrame, settings: burnSettings,
                            subtitles: srt) { _ in }
    let burnInfo = try await FFmpeg.probe(url: burnOut)
    equal(burnInfo.width, info.width, "a captioned export keeps its dimensions")
    check(abs(burnInfo.duration - info.duration) < 0.25, "and its duration",
          "\(burnInfo.duration) vs \(info.duration)")
} else {
    print("  --   caption rendering skipped (this ffmpeg has no libass)")
}

// MARK: - Non-destructive editing and project round trips

print("\nTimeline ruler")

// The ladder must stay sorted, or `interval` cannot pick the finest fit by scanning it.
let ladder = TimelineRuler.intervals(fps: 30)
check(zip(ladder, ladder.dropFirst()).allSatisfy { $0 < $1 }, "the interval ladder is sorted finest first")

// The defect this replaces: a fixed tick count spreads labels further apart the further
// you zoom, so most of the timeline carried no time reference. Across four decades of
// magnification every chosen interval must stay legible and must come from the ladder.
let coarsest = ladder[ladder.count - 1]
let scales = stride(from: -1.0, through: 3.0, by: 0.1).map { pow(10, $0) }
var spacings: [Double] = []
var offLadder: Double?
for pixelsPerSecond in scales {
    let interval = TimelineRuler.interval(pixelsPerSecond: pixelsPerSecond, fps: 30)
    if !ladder.contains(interval) { offLadder = pixelsPerSecond }
    // The coarsest interval is a floor: past it there is nothing wider to choose.
    if interval != coarsest { spacings.append(interval * pixelsPerSecond) }
}
check(offLadder == nil, "every chosen interval comes from the ladder",
      offLadder.map { "off-ladder at \(Int($0))px/s" } ?? "\(scales.count) scales")
check(spacings.allSatisfy { $0 >= TimelineRuler.minimumSpacing }, "labels never fall closer than the minimum",
      "tightest \(spacings.min().map { String(format: "%.1f", $0) } ?? "none")")
check(spacings.allSatisfy { $0 < 210 }, "and never spread further than the ladder's largest step allows",
      "widest \(spacings.max().map { String(format: "%.1f", $0) } ?? "none")")

// Zooming in must never coarsen the ruler.
var previous = coarsest
var coarsened: Double?
for pixelsPerSecond in scales {
    let interval = TimelineRuler.interval(pixelsPerSecond: pixelsPerSecond, fps: 30)
    if interval > previous { coarsened = pixelsPerSecond }
    previous = interval
}
check(coarsened == nil, "the ruler only ever gets finer as it is zoomed in",
      coarsened.map { "coarsened at \(Int($0))px/s" } ?? "monotonic")

equal(TimelineRuler.interval(pixelsPerSecond: 0, fps: 30), coarsest, "a degenerate scale falls back to the coarsest interval")
equal(TimelineRuler.interval(pixelsPerSecond: .nan, fps: 30), coarsest, "and so does a non-finite one")

// Minor ticks are dropped rather than drawn as a smear.
check(TimelineRuler.minorInterval(1, pixelsPerSecond: 100) != nil, "minor ticks appear when there is room")
check(TimelineRuler.minorInterval(1, pixelsPerSecond: 20) == nil, "and are dropped when there is not")

equal(TimelineRuler.ticks(every: 5, in: 0...20), [0, 5, 10, 15, 20], "ticks include both ends")
equal(TimelineRuler.ticks(every: 5, in: 6...19), [10, 15], "and only whole multiples inside the range")
check(TimelineRuler.ticks(every: 0, in: 0...10).isEmpty, "a zero step yields no ticks")
check(TimelineRuler.ticks(every: 0.0001, in: 0...100).isEmpty, "an absurd tick count is refused rather than drawn")

// Labels carry frames only when ticks are closer together than a second.
equal(TimelineRuler.label(75, interval: 5, fps: 30), "1:15", "a coarse label drops the fraction")
equal(TimelineRuler.label(75.5, interval: 0.2, fps: 30), "1:15.15", "a fine label counts frames instead")
equal(TimelineRuler.label(0, interval: 1, fps: 30), "0:00", "zero formats cleanly")
equal(TimelineRuler.label(-4, interval: 1, fps: 30), "0:00", "and so does a negative time")
equal(TimelineRuler.label(1, interval: 0.5, fps: 0), "0:01.00", "a missing frame rate falls back instead of dividing by zero")


print("\nTimeline viewport")

// The defect this replaces: zoom used to scale a canvas inside a scroll view, so the
// moment you were looking at slid away as you magnified. Whatever the anchor, it must
// stay at the same point across the width.
let anchorWidth = 900.0
var anchorDrift = 0.0
for anchorFraction in [0.0, 0.25, 0.5, 0.75, 1.0] {
    for factor in [1.5, 4.0, 0.5, 1 / 3.0] {
        var port = TimelineViewport(total: 600)
        port.zoom(to: 6, keeping: 300)          // start part-way in, away from either end
        let anchor = port.start + port.visible * anchorFraction
        let before = port.x(of: anchor, across: anchorWidth)
        port.zoom(by: factor, keeping: anchor)
        anchorDrift = max(anchorDrift, abs(port.x(of: anchor, across: anchorWidth) - before))
    }
}
check(anchorDrift < 0.001, "zooming holds the anchored moment still",
      String(format: "worst drift %.4fpt", anchorDrift))

// x and time must be exact inverses, or scrubbing lands somewhere other than the click.
var port = TimelineViewport(total: 600)
port.zoom(to: 12, keeping: 200)
var roundTrip = 0.0
for x in [0.0, 1.0, 450.0, 899.0, 900.0] {
    roundTrip = max(roundTrip, abs(port.x(of: port.time(atX: x, across: anchorWidth), across: anchorWidth) - x))
}
check(roundTrip < 0.000001, "a point converts to a time and back unchanged",
      String(format: "worst %.8f", roundTrip))

// The window may never leave the recording, however hard it is pushed.
var edge = TimelineViewport(total: 600)
edge.zoom(to: 10, keeping: 0)
edge.pan(by: -10_000)
equal(edge.start, 0, "panning stops at the beginning")
edge.pan(by: 10_000)
check(abs(edge.end - 600) < 0.000001, "and at the end", "\(edge.end)")
check(edge.start >= 0 && edge.end <= 600.000001, "the window stays inside the recording")

// Zoom limits.
var limit = TimelineViewport(total: 600)
limit.zoom(to: 1000, keeping: 300)
equal(limit.scale, TimelineViewport.maximumScale, "zoom stops at the finest scale")
limit.zoom(to: 0.01, keeping: 300)
equal(limit.scale, 1, "and zooming out stops at the whole recording")
equal(limit.visible, 600, "which is the whole timeline across the width")
equal(limit.start, 0, "anchored back at the beginning")

var degenerate = TimelineViewport(total: 600)
degenerate.zoom(to: .nan, keeping: .nan)
check(degenerate.visible.isFinite && degenerate.start.isFinite, "a non-finite zoom cannot corrupt the viewport")
degenerate.pan(by: .infinity)
check(degenerate.start.isFinite && degenerate.start >= 0, "nor can a non-finite pan")

// Following the playhead: only when it leaves the margin, and never past the ends.
var follow = TimelineViewport(total: 600)
follow.zoom(to: 10, keeping: 300)   // 60s visible around 300
let settled = follow.start
follow.reveal(follow.start + follow.visible / 2)
equal(follow.start, settled, "a playhead in clear view does not move the timeline")
follow.reveal(follow.end + 5)
check(follow.contains(follow.end - follow.visible * 0.12 + 0.001), "a playhead that runs off the end pulls the view along")
check(follow.start >= 0 && follow.end <= 600.000001, "and following still cannot leave the recording")
follow.reveal(0)
equal(follow.start, 0, "revealing the very start sits flush against it")

// An edit that changes the timeline's length must not strand the window past the end.
var resized = TimelineViewport(total: 600)
resized.zoom(to: 20, keeping: 590)
resized.resize(total: 100)
check(resized.end <= 100.000001, "shortening the timeline pulls the window back inside", "\(resized.end)")
check(resized.visible <= 100.000001, "and never shows more than there is")
resized.resize(total: 0)
check(resized.visible > 0 && resized.scale >= 1, "an empty timeline still leaves a usable viewport")

// Culling: only what is on screen is worth building.
var culling = TimelineViewport(total: 600)
culling.zoom(to: 60, keeping: 300)
check(culling.intersects(culling.start - 1, culling.start + 1), "a section straddling the left edge is drawn")
check(culling.intersects(culling.end - 1, culling.end + 1), "and one straddling the right edge")
check(!culling.intersects(0, culling.start - 0.001), "but one entirely before the window is not")
check(!culling.intersects(culling.end + 0.001, 600), "nor one entirely after it")
check(culling.visible < 600 / 59, "sixty times is genuinely sixty times")

// The ruler ladder is frame-derived below half a second, so fine labels land on whole
// frames rather than rounding two ticks onto the same one.
for fps in [24.0, 25.0, 30.0, 60.0] {
    let fine = TimelineRuler.intervals(fps: fps).filter { $0 < 0.5 }
    let whole = fine.allSatisfy { abs(($0 * fps).rounded() - $0 * fps) < 0.000001 }
    check(whole, "every sub-second rung is a whole number of frames at \(Int(fps))fps")
}

print("\nTimeline and projects")
let wholeTimeline = ClipTimeline(segments: [TimelineSegment(start: 0, end: 10)])
var splitTimeline = wholeTimeline
check(splitTimeline.split(at: 0, fps: 30) == nil, "cannot split at the start boundary")
check(splitTimeline.split(at: 10, fps: 30) == nil, "cannot split at the end boundary")
let rightID = splitTimeline.split(at: 4.01, fps: 30)
check(rightID != nil, "splits inside a section")
equal(splitTimeline.segments[0].end, 4, "split snaps to a source frame")
equal(splitTimeline.duration, 10, "splitting preserves duration")
equal(splitTimeline.location(at: 4)?.index, 1, "cut boundary belongs to the next section")
let reordered = ClipTimeline(segments: [splitTimeline.segments[1], splitTimeline.segments[0]])
equal(reordered.location(at: 0)?.source, 4, "reordered timeline starts at the moved source range")
equal(reordered.location(at: 7)?.source, 1, "source lookup follows reordered sections")
let anchored = ZoomShot(start: 5, hold: 1, level: 2, target: CGPoint(x: 200, y: 100))
equal(reordered.remap([anchored], from: wholeTimeline).first?.start, 1, "zoom follows retained footage when reordered")
let removedTimeline = ClipTimeline(segments: [TimelineSegment(start: 0, end: 4)])
check(removedTimeline.remap([anchored], from: wholeTimeline).isEmpty, "deleting a zoom's source removes that zoom")

var projectItem = VideoItem(url: landscape)
projectItem.info = info; projectItem.crop = info.fullFrame
projectItem.segments = [TimelineSegment(start: 1.5, end: 3), TimelineSegment(start: 0, end: 1)]
projectItem.zoomShots = [ZoomShot(start: 0.2, hold: 0.5, level: 2, target: CGPoint(x: 640, y: 360))]
let roundTripProject = VideoProject(clips: [ProjectClip(projectItem)], settings: ExportSettings(), selection: projectItem.id)
let decodedProject = try JSONDecoder().decode(VideoProject.self, from: JSONEncoder().encode(roundTripProject))
try decodedProject.validate()
equal(decodedProject, roundTripProject, "project round trip retains cuts, zooms, geometry and settings")
var invalidProject = decodedProject
invalidProject.clips[0].segments?[0].end = 999
check((try? invalidProject.validate()) == nil, "rejects out-of-bounds source ranges")
invalidProject = decodedProject
invalidProject.version = 200
check((try? invalidProject.validate()) == nil, "rejects unsupported project versions")

let editor = AppModel(recoveryURL: nil)
editor.restore(roundTripProject)
editor.setPreviewFraction(0.25)
let originalSections = editor.selectedItem!.timeline.segments
editor.splitAtPlayhead()
equal(editor.selectedItem!.timeline.segments.count, 3, "editor splits a section")
editor.undoEdit()
equal(editor.selectedItem!.timeline.segments, originalSections, "undo restores the exact source ranges")
editor.redoEdit()
equal(editor.selectedItem!.timeline.segments.count, 3, "redo restores the split")
editor.deleteSegment()
equal(editor.selectedItem!.timeline.segments.count, 2, "deleting a section closes its gap")
editor.undoEdit()
equal(editor.selectedItem!.timeline.segments.count, 3, "undo restores the deleted section")
let namedProject = scratch.appendingPathComponent("round-trip.yamvideo")
try editor.writeProject(roundTripProject, to: namedProject)
editor.openProject(at: namedProject)
equal(editor.project.clips, roundTripProject.clips, "opening a saved project restores edit data")

// MARK: - Project identity and the version 3 schema

print("\nProject identity")
var legacy = roundTripProject
legacy.version = 2; legacy.projectID = nil
let legacyData = try JSONEncoder().encode(legacy)
let migrated = try VideoProject.decodeMigrating(from: legacyData)
equal(migrated.version, VideoProject.currentVersion, "a version 2 file is upgraded on open")
check(migrated.projectID != nil, "an upgraded file gains an identity")
equal(try VideoProject.decodeMigrating(from: legacyData).projectID, migrated.projectID,
      "the same legacy bytes always get the same identity")
var otherLegacy = legacy; otherLegacy.settings.quality = 10
check(try VideoProject.decodeMigrating(from: JSONEncoder().encode(otherLegacy)).projectID != migrated.projectID,
      "different legacy files get different identities")
equal(migrated.clips, legacy.clips, "upgrading changes no edit data")

var newerFields = legacy; newerFields.clips[0].subtitles = srt
check((try? newerFields.validate()) == nil, "an older version carrying subtitles is rejected")
newerFields = legacy; newerFields.projectID = UUID()
check((try? newerFields.validate()) == nil, "an older version carrying an identity is rejected")
var anonymous = roundTripProject; anonymous.projectID = nil
check((try? anonymous.validate()) == nil, "a version 3 file without an identity is rejected")
var future = roundTripProject; future.version = VideoProject.currentVersion + 1
do {
    try future.validate()
    check(false, "a newer version is rejected")
} catch {
    check(error.localizedDescription.contains("newer version"), "a newer version is rejected with a clear reason",
          error.localizedDescription)
}

let identityEditor = AppModel(recoveryURL: nil)
let legacyFile = scratch.appendingPathComponent("legacy.yamvideo")
try legacyData.write(to: legacyFile)
identityEditor.openProject(at: legacyFile)
equal(identityEditor.projectID, migrated.projectID, "opening a legacy file adopts its derived identity")
check(!identityEditor.hasUnsavedChanges, "upgrading on open is not an unsaved edit")
identityEditor.saveProject()
let resaved = try JSONDecoder().decode(VideoProject.self, from: Data(contentsOf: legacyFile))
equal(resaved.version, VideoProject.currentVersion, "saving writes the current version")
equal(resaved.projectID, migrated.projectID, "saving persists the identity")
identityEditor.openProject(at: legacyFile)
equal(identityEditor.projectID, migrated.projectID, "the identity survives save and reopen")

// The subtitle file is project data now: undoable, saved, recovered.
identityEditor.setSubtitles(srt, for: identityEditor.selectedItem!.id)
equal(identityEditor.project.clips[0].subtitles, srt, "the chosen subtitle file is part of the project")
check(identityEditor.hasUnsavedChanges, "choosing subtitles marks the project changed")
identityEditor.undoEdit()
equal(identityEditor.selectedItem!.subtitles, nil, "undo removes the subtitle choice")
identityEditor.redoEdit()
identityEditor.saveProject()
identityEditor.openProject(at: legacyFile)
equal(identityEditor.selectedItem!.subtitles, srt, "the subtitle choice survives save and reopen")

// Save As forks the document; saving in place does not.
let originalID = identityEditor.projectID
let copyFile = scratch.appendingPathComponent("copy.yamvideo")
identityEditor.save(to: copyFile, asCopy: true)
check(identityEditor.projectID != originalID, "Save As gives the copy its own identity")
equal(identityEditor.projectURL, copyFile, "Save As continues editing the copy")
check(!identityEditor.hasUnsavedChanges, "the forked copy is saved")
equal(try JSONDecoder().decode(VideoProject.self, from: Data(contentsOf: legacyFile)).projectID, originalID,
      "the original file keeps its identity")
let copyID = identityEditor.projectID
identityEditor.saveProject()
equal(identityEditor.projectID, copyID, "saving in place keeps the identity")
identityEditor.newProject()
check(identityEditor.projectID != copyID, "a new project has its own identity")
identityEditor.undoEdit()
equal(identityEditor.projectID, copyID, "undoing New Project restores the previous identity")

let identityRecovery = scratch.appendingPathComponent("identity-recovery.yamvideo")
let recoveringIdentity = AppModel(recoveryURL: identityRecovery)
recoveringIdentity.restore(identityEditor.project)
recoveringIdentity.flushRecovery()
let resumedIdentity = AppModel(recoveryURL: identityRecovery)
equal(resumedIdentity.projectID, identityEditor.projectID, "recovery keeps the project identity")
equal(resumedIdentity.selectedItem?.subtitles, srt, "recovery keeps the subtitle choice")

let legacyRecovery = scratch.appendingPathComponent("legacy-recovery.yamvideo")
try JSONEncoder().encode(SessionRecovery(project: legacy, fileURL: legacyFile, savedProject: legacy))
    .write(to: legacyRecovery)
let legacyResumed = AppModel(recoveryURL: legacyRecovery)
check(legacyResumed.savedProject?.projectID == legacyResumed.projectID,
      "a legacy recovery file upgrades its saved copy to the same identity")
check(!legacyResumed.hasUnsavedChanges, "an upgraded recovery file is not mistaken for unsaved edits")

// MARK: - Shared edit commands

print("\nShared edit commands")
func refusal(_ result: Result<EditReceipt, EditError>) -> EditError.Code? {
    if case .failure(let error) = result { return error.code }
    return nil
}
func receipt(_ result: Result<EditReceipt, EditError>) -> EditReceipt? {
    if case .success(let value) = result { return value }
    return nil
}
func reducerRefusal(_ commands: [EditCommand], _ project: VideoProject = roundTripProject) -> EditError.Code? {
    do { _ = try ProjectReducer.apply(commands, to: project); return nil }
    catch let error as EditError { return error.code }
    catch { return .invalidCommand }
}
@MainActor func freshEditor() -> AppModel {
    let model = AppModel(recoveryURL: nil)
    model.restore(roundTripProject)
    return model
}
let commandClip = roundTripProject.clips[0]
let sectionA = commandClip.timeline.segments[0], sectionB = commandClip.timeline.segments[1]
let anchoredZoom = commandClip.zoomShots[0]

// The reducer: pure, strict, all or nothing.
equal(reducerRefusal([
    .setSectionSpeed(clip: commandClip.id, section: sectionA.id, speed: 2),
    .setCrop(clip: commandClip.id, rect: CGRect(x: 0, y: 0, width: 640, height: 360)),
    .setSectionSpeed(clip: commandClip.id, section: sectionB.id, speed: 9),
]), .invalidCommand, "a batch with one invalid command is refused as a whole")
equal(reducerRefusal([.trimSection(clip: commandClip.id, section: UUID(), start: 0, end: nil)]), .notFound,
      "an unknown section is reported as not found")
equal(reducerRefusal([.trimSection(clip: commandClip.id, section: sectionA.id, start: nil, end: 99)]), .invalidCommand,
      "a trim past the source is refused, not clamped")
equal(reducerRefusal([.trimSection(clip: commandClip.id, section: sectionB.id, start: nil, end: 1.6)]), .invalidCommand,
      "a trim into a neighbouring section's footage is refused")
let snapped = try ProjectReducer.apply([.trimSection(clip: commandClip.id, section: sectionA.id, start: 1.517, end: nil)],
                                       to: roundTripProject)
check(abs(snapped.project.clips[0].segments![0].start - 46.0 / 30) < 0.000001, "trim bounds snap to a source frame")
let splitOutcome = try ProjectReducer.apply([.splitSection(clip: commandClip.id, at: 0.5)], to: roundTripProject)
check(splitOutcome.createdIDs.count == 1 && splitOutcome.project.clips[0].segments!.count == 3,
      "a split reports the new section's ID")
equal(reducerRefusal([.splitSection(clip: commandClip.id, at: 0)]), .invalidCommand, "splitting on a boundary is refused")
let cutZoom = try ProjectReducer.apply([.deleteSection(clip: commandClip.id, section: sectionA.id)], to: roundTripProject)
equal(cutZoom.removedZooms, [anchoredZoom.id], "deleting a zoom's footage reports the zoom it removed")
var edgeZoom = anchoredZoom; edgeZoom.target = CGPoint(x: 1280, y: 720)
equal(reducerRefusal([.updateZoom(clip: commandClip.id, zoom: edgeZoom)]), nil, "a zoom may aim at the frame's far edge")
equal(reducerRefusal([.addZoom(clip: commandClip.id, zoom: ZoomShot(start: 0.3, hold: 0.5, target: .zero))]),
      .invalidCommand, "an overlapping zoom is refused")
equal(reducerRefusal([.setMovieOrder([])]), .invalidCommand, "a movie order must list every recording")
var badSettings = ExportSettings(); badSettings.quality = 150
equal(reducerRefusal([.setExportSettings(badSettings)]), .invalidCommand, "out-of-range export settings are refused")
equal(reducerRefusal([.setAspect(clip: commandClip.id, preset: "7:3")]), .invalidCommand, "an unknown aspect is refused")

// Revisions: one per transaction, none for a no-op.
let revisions = freshEditor()
let clipID = revisions.items[0].id
let firstRevision = revisions.revision
revisions.perform([.setSectionSpeed(clip: clipID, section: sectionA.id, speed: 1.5)])
equal(revisions.revision, firstRevision + 1, "a transaction advances the revision once")
let historyDepth = revisions.undoEntries.count
revisions.perform([.setSectionSpeed(clip: clipID, section: sectionA.id, speed: 1.5)])
check(revisions.revision == firstRevision + 1 && revisions.undoEntries.count == historyDepth,
      "a no-op changes neither the revision nor history")

// Two agents planning against the same revision: one wins, one is told to reread.
let atRevision = revisions.revision
let wide = CGRect(x: 0, y: 0, width: 640, height: 360)
let codexCrop = revisions.perform([.setCrop(clip: clipID, rect: wide)], origin: .agent("Codex"), expectedRevision: atRevision)
let claudeCrop = revisions.perform([.setCrop(clip: clipID, rect: CGRect(x: 100, y: 100, width: 320, height: 180))],
                                   origin: .agent("Claude"), expectedRevision: atRevision)
check(receipt(codexCrop) != nil, "the first agent's edit at a revision commits")
equal(refusal(claudeCrop), .revisionConflict, "the second agent's edit at the same revision conflicts")
equal(revisions.items[0].crop, wide, "the conflicting edit did not overwrite the first")
check(receipt(revisions.perform([.setAspect(clip: clipID, preset: "16:9")], origin: .agent("Claude"),
                                expectedRevision: revisions.revision)) != nil, "after rereading, the second agent succeeds")

// Dry run: the same validation and remap report, nothing committed or reserved.
let dryEditor = freshEditor()
let dryBefore = dryEditor.project, dryRevision = dryEditor.revision, dryHistory = dryEditor.undoEntries.count
let dry = receipt(dryEditor.perform([.deleteSection(clip: clipID, section: sectionA.id)], origin: .agent("Codex"),
                                    expectedRevision: dryRevision, dryRun: true))
check(dryEditor.project == dryBefore && dryEditor.revision == dryRevision && dryEditor.undoEntries.count == dryHistory,
      "a dry run commits nothing")
let wet = receipt(dryEditor.perform([.deleteSection(clip: clipID, section: sectionA.id)], origin: .agent("Codex"),
                                    expectedRevision: dryRevision))
check(dry?.removedZooms == [anchoredZoom.id] && wet?.removedZooms == dry?.removedZooms,
      "a dry run reports the same zoom losses as the real edit")

// A drag is one gesture: live while held, one transaction when released.
let dragging = freshEditor()
let dragStart = dragging.revision, dragHistory = dragging.undoEntries.count
let heldCrop = CGRect(x: 10, y: 10, width: 900, height: 500)
dragging.updateCrop(CGRect(x: 0, y: 0, width: 1000, height: 600), live: true)
dragging.updateCrop(heldCrop, live: true)
equal(dragging.items[0].crop, heldCrop, "a drag is visible while it lasts")
equal(dragging.revision, dragStart, "live drag updates commit nothing")
equal(dragging.committedProject.clips[0].crop, commandClip.crop, "agents see the committed crop during a drag")
dragging.editSession.gesture?.lastUpdate = Date().addingTimeInterval(-0.9)
equal(refusal(dragging.perform([.setAspect(clip: clipID, preset: "1:1")], origin: .agent("Claude"),
                               expectedRevision: dragging.revision)),
      .interactionInProgress, "an agent edit during a held drag is refused clearly")
dragging.updateCrop(CGRect(x: 20, y: 20, width: 800, height: 400), live: true)
dragging.updateCrop(.null, live: false)
check(dragging.revision == dragStart + 1 && dragging.undoEntries.count == dragHistory + 1,
      "a drag held past 0.6 s is still one revision and one undo step")
check(receipt(dragging.perform([.setAspect(clip: clipID, preset: "1:1")], origin: .agent("Claude"),
                               expectedRevision: dragging.revision)) != nil,
      "after the drag ends, the agent's edit succeeds on rereading")
dragging.undoEdit(); dragging.undoEdit()
equal(dragging.items[0].crop, commandClip.crop, "undo restores the crop from before the whole drag")
let cancelStart = dragging.revision, cancelHistory = dragging.undoEntries.count
dragging.updateCrop(heldCrop, live: true)
dragging.cancelGesture()
check(dragging.revision == cancelStart && dragging.undoEntries.count == cancelHistory
          && dragging.items[0].crop == commandClip.crop, "a cancelled drag leaves no history or revision")
dragging.updateCrop(heldCrop, live: true)
dragging.editSession.gesture?.lastUpdate = .distantPast
check(receipt(dragging.perform([.setAspect(clip: clipID, preset: "4:3")], origin: .agent("Claude"),
                               expectedRevision: dragging.revision)) == nil,
      "an abandoned drag is committed first, so the agent's old revision no longer matches")
equal(dragging.items[0].crop, heldCrop, "an abandoned drag is kept rather than lost")
let gestureHistory = dragging.undoEntries.count
dragging.setPreviewFraction(0.3)
dragging.updateCrop(wide, live: true)
dragging.splitAtPlayhead()
equal(dragging.undoEntries.count, gestureHistory + 2, "a separate command closes an open drag as its own step")
let sliderHistory = dragging.undoEntries.count
var sliding = dragging.settings
for quality in [40.0, 45, 50] { sliding.quality = quality; dragging.updateSettings(sliding, live: true) }
dragging.endGesture()
check(dragging.undoEntries.count == sliderHistory + 1 && dragging.settings.quality == 50,
      "a slider drag is one undo step with its final value")

// Human and agent edits interleave in one history.
let mixed = freshEditor()
mixed.perform([.setCrop(clip: clipID, rect: wide)])
let afterCrop = mixed.project.clips
let blur = BlurRegion(rect: CGRect(x: 40, y: 40, width: 100, height: 60))
let agentBlur = receipt(mixed.perform([.addBlurArea(clip: clipID, area: blur)], origin: .agent("Claude"),
                                      expectedRevision: mixed.revision))!
let afterBlur = mixed.project.clips
mixed.perform([.setAspect(clip: clipID, preset: "1:1")])
equal(mixed.undoTitle, "Undo Crop Aspect", "the menu names the owner's own step plainly")
mixed.undoEdit()
equal(mixed.project.clips, afterBlur, "Cmd-Z restores the exact previous document")
equal(mixed.undoTitle, "Undo Add Blur (Claude)", "the menu names an agent's step and who made it")
check(receipt(mixed.undo(origin: .agent("Claude"), expectedTransaction: agentBlur.transactionID,
                         expectedRevision: mixed.revision)) != nil, "an agent can undo its own step when it is on top")
equal(mixed.project.clips, afterCrop, "the agent's undo restores the document before its edit")
mixed.redoEdit()
equal(mixed.project.clips, afterBlur, "redo restores the agent's edit")
mixed.perform([.setAspect(clip: clipID, preset: "4:3")])
check(mixed.redoEntries.isEmpty, "a new edit clears redo")
equal(refusal(mixed.undo(origin: .agent("Claude"), expectedTransaction: agentBlur.transactionID,
                         expectedRevision: mixed.revision)),
      .historyConflict, "an agent cannot undo across somebody else's later edit")
let ownStep = receipt(mixed.perform([.setAspect(clip: clipID, preset: "1:1")], origin: .agent("Codex"),
                                    expectedRevision: mixed.revision))!
mixed.setPreviewFraction(0.7)
mixed.selectedSegmentID = sectionB.id
mixed.undo(origin: .agent("Codex"), expectedTransaction: ownStep.transactionID, expectedRevision: mixed.revision)
check(abs(mixed.items[0].previewFraction - 0.7) < 0.000001 && mixed.selectedSegmentID == sectionB.id,
      "an agent's undo leaves the owner's playhead and selection alone")
check(mixed.editSession.events.contains { $0.kind == .undo && $0.origin == .agent("Codex") },
      "the change feed records an agent's undo and who asked")

mixed.agentsPaused = true
equal(refusal(mixed.perform([.setAspect(clip: clipID, preset: "Free")], origin: .agent("Codex"),
                            expectedRevision: mixed.revision)), .agentsPaused, "paused agents cannot edit")
mixed.agentsPaused = false
mixed.isConverting = true
equal(refusal(mixed.perform([.setAspect(clip: clipID, preset: "Free")], origin: .agent("Codex"),
                            expectedRevision: mixed.revision)), .exportInProgress, "agents cannot edit during an export")
mixed.isConverting = false

// Sessions: a different document, or the same file opened afresh, is a new session.
let firstSession = mixed.editSession.sessionID
mixed.newProject()
check(mixed.editSession.sessionID != firstSession, "a new project starts a new session")
let emptySession = mixed.editSession.sessionID
mixed.undoEdit()
check(mixed.editSession.sessionID != emptySession, "undoing back to the previous project starts another session")
mixed.openProject(at: namedProject)
let openedSession = mixed.editSession.sessionID
mixed.openProject(at: namedProject)
check(mixed.editSession.sessionID != openedSession, "reopening the same file is a new session")
for _ in 0..<1100 { mixed.appendEvent(.edit, origin: .human, label: "filler") }
equal(mixed.editSession.events.count, EditSessionState.eventLimit, "the change feed keeps a bounded history")

// A probe that finishes after Add is a fact about the file, not an undo step.
let probing = AppModel(recoveryURL: nil)
probing.perform([.addMedia([ProjectClip(VideoItem(url: landscape))])])
let probedID = probing.items[0].id
let probeHistory = probing.undoEntries.count
probing.resolveMedia(probedID, info: info, subtitles: nil)
equal(probing.undoEntries.count, probeHistory, "a finished probe adds no undo step")
probing.undoEdit(); probing.redoEdit()
equal(probing.items.first?.info, info, "undo and redo do not forget a probe that finished after Add")

// MARK: - Actual reordered video/audio exports and native playback

print("\nEdited video and playback")
let colorSource = scratch.appendingPathComponent("colors.mp4")
let colors = try await Shell.run(ffmpeg, [
    "-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi", "-i",
    "color=c=red:s=320x180:r=30:d=1[r];color=c=green:s=320x180:r=30:d=1[g];color=c=blue:s=320x180:r=30:d=1[b];[r][g][b]concat=n=3:v=1:a=0",
    "-f", "lavfi", "-i", #"aevalsrc=sin(2*PI*t*if(lt(t\,1)\,440\,if(lt(t\,2)\,880\,1320))):s=48000:d=3"#,
    "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", "-t", "3", colorSource.path
])
check(colors.status == 0, "creates distinguishable video and audio sections", colors.stderrText)
let colorInfo = try await FFmpeg.probe(url: colorSource)
let edits = [TimelineSegment(start: 2, end: 2.7), TimelineSegment(start: 0.2, end: 0.8)]
var editedSettings = ExportSettings()
editedSettings.audio = .copy
let editedOut = scratch.appendingPathComponent("edited.mp4")
try await FFmpeg.export(input: colorSource, output: editedOut, info: colorInfo, crop: colorInfo.fullFrame,
                        segments: edits, settings: editedSettings) { _ in }
let editedInfo = try await FFmpeg.probe(url: editedOut)
check(abs(editedInfo.duration - 1.3) < 0.06, "export duration equals retained sections", "\(editedInfo.duration)")
equal(try await frameCount(editedOut), 39, "edited export has exactly 39 frames")
equal(editedInfo.audioCodec, "aac", "cut audio is encoded even when Copy was selected")
let firstColor = try await pixel(editedOut, x: 150, y: 80, at: 0.1)
let secondColor = try await pixel(editedOut, x: 150, y: 80, at: 0.9)
check(firstColor.2 > 200 && firstColor.0 < 40, "export starts with the moved blue section")
check(secondColor.0 > 200 && secondColor.2 < 40, "export cuts directly to the retained red section")

func toneFrequency(_ url: URL, at time: Double) async throws -> Double {
    let data = try await Shell.run(ffmpeg, ["-v", "error", "-ss", String(time), "-i", url.path,
        "-t", "0.3", "-vn", "-ac", "1", "-ar", "8000", "-f", "s16le", "-"])
    let bytes = [UInt8](data.stdout)
    let samples = stride(from: 0, to: bytes.count - 1, by: 2).map { Int16(bitPattern: UInt16(bytes[$0]) | UInt16(bytes[$0 + 1]) << 8) }
    let crossings = zip(samples, samples.dropFirst()).filter { $0 <= 0 && $1 > 0 }.count
    return Double(crossings) * 8000 / Double(max(1, samples.count))
}
check(abs(try await toneFrequency(editedOut, at: 0.1) - 1320) < 15, "audio follows the moved blue section")
check(abs(try await toneFrequency(editedOut, at: 0.85) - 440) < 15, "audio changes with the cut to red")

var editedGIFSettings = ExportSettings()
editedGIFSettings.format = .gif
let editedGIF = scratch.appendingPathComponent("edited.gif")
try await FFmpeg.export(input: colorSource, output: editedGIF, info: colorInfo, crop: colorInfo.fullFrame,
                        segments: edits, settings: editedGIFSettings) { _ in }
check(abs(try await frameCount(editedGIF) - 20) <= 1, "GIF palette and encode both honor the timeline")
let gifFirst = try await pixel(editedGIF, x: 100, y: 80, at: 0.1)
check(gifFirst.2 > 200 && gifFirst.0 < 40, "edited GIF preserves section order")

var nativeClip = VideoItem(url: colorSource)
nativeClip.info = colorInfo; nativeClip.crop = colorInfo.fullFrame; nativeClip.segments = edits
let nativeItem = try await PlaybackController.makeItem(nativeClip, settings: ExportSettings())
let nativeGenerator = AVAssetImageGenerator(asset: nativeItem.asset)
nativeGenerator.videoComposition = nativeItem.videoComposition
nativeGenerator.requestedTimeToleranceBefore = .zero; nativeGenerator.requestedTimeToleranceAfter = .zero
let nativeBlue = try await nativeGenerator.image(at: CMTime(seconds: 0.1, preferredTimescale: 600)).image
let nativeRed = try await nativeGenerator.image(at: CMTime(seconds: 0.9, preferredTimescale: 600)).image
func nativePixel(_ image: CGImage, x: Int, y: Int) -> (Int, Int, Int) {
    let bitmap = NSBitmapImageRep(cgImage: image)
    guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return (0, 0, 0) }
    return (Int(color.redComponent * 255), Int(color.greenComponent * 255), Int(color.blueComponent * 255))
}
let previewBlue = nativePixel(nativeBlue, x: 100, y: 80)
let previewRed = nativePixel(nativeRed, x: 100, y: 80)
check(previewBlue.2 > 200 && previewBlue.0 < 40, "native playback uses the moved first section")
check(previewRed.0 > 200 && previewRed.2 < 40, "native playback cuts at the same time as export")

// Use the existing marker fixture to verify Core Image's crop/zoom coordinate system.
var nativeMarker = VideoItem(url: markerClip)
nativeMarker.info = markerInfo; nativeMarker.crop = CGRect(x: 100, y: 50, width: 1000, height: 600)
nativeMarker.zoomShots = [ZoomShot(start: 0.5, hold: 1, level: 2, target: CGPoint(x: 930, y: 530))]
let markerPlayer = try await PlaybackController.makeItem(nativeMarker, settings: ExportSettings())
let markerGenerator = AVAssetImageGenerator(asset: markerPlayer.asset)
markerGenerator.videoComposition = markerPlayer.videoComposition
let markerPreview = try await markerGenerator.image(at: CMTime(seconds: 1.5, preferredTimescale: 600)).image
check(markerPreview.width == 1000 && markerPreview.height == 600, "native cropped preview uses export dimensions")
let renderedPNG = scratch.appendingPathComponent("native-zoom.png")
try NSBitmapImageRep(cgImage: markerPreview).representation(using: .png, properties: [:])!.write(to: renderedPNG)
let nativeBox = try await markerBox(renderedPNG, at: 0, size: CGSize(width: 1000, height: 600))
check(nativeBox != nil && nativeBox!.width > 100, "native preview applies the zoom to the marker", "\(String(describing: nativeBox))")

// Coordinate parity, including a rotated source, is essential for usable previews.
let parityExport = scratch.appendingPathComponent("native-parity.mp4")
try await FFmpeg.export(input: markerClip, output: parityExport, info: markerInfo,
    crop: nativeMarker.crop!, zoomShots: nativeMarker.zoomShots, settings: ExportSettings()) { _ in }
let parityBox = try await markerBox(parityExport, at: 1.5, size: CGSize(width: 1000, height: 600))
check(nativeBox != nil && parityBox != nil && abs(nativeBox!.midX - parityBox!.midX) < 5 && abs(nativeBox!.midY - parityBox!.midY) < 5,
      "native crop/zoom placement agrees with exported frames", "native \(String(describing: nativeBox)); export \(String(describing: parityBox))")
if let rotated {
    var portrait = VideoItem(url: rotated)
    portrait.info = try await FFmpeg.probe(url: rotated)
    portrait.crop = CGRect(x: 0, y: 100, width: 720, height: 900)
    portrait.blurRegions = [BlurRegion(rect: CGRect(x: 100, y: 200, width: 100, height: 100))]
    var portraitSettings = ExportSettings(); portraitSettings.blurStyle = .black
    let portraitPlayer = try await PlaybackController.makeItem(portrait, settings: portraitSettings)
    let generator = AVAssetImageGenerator(asset: portraitPlayer.asset)
    generator.videoComposition = portraitPlayer.videoComposition
    let frame = try await generator.image(at: CMTime(seconds: 0.5, preferredTimescale: 600)).image
    check(frame.width == 720 && frame.height == 900, "native preview respects rotated crop dimensions")
    let black = nativePixel(frame, x: 150, y: 150)
    check(black.0 < 15 && black.1 < 15 && black.2 < 15, "native redaction respects rotated source coordinates")
}

let recoveryPath = scratch.appendingPathComponent("recovery.yamvideo")
let recoveringEditor = AppModel(recoveryURL: recoveryPath)
recoveringEditor.restore(roundTripProject)
recoveringEditor.projectURL = namedProject
recoveringEditor.savedProject = roundTripProject
recoveringEditor.setPreviewFraction(0.25)
recoveringEditor.splitAtPlayhead()
recoveringEditor.flushRecovery()
let resumedEditor = AppModel(recoveryURL: recoveryPath)
equal(resumedEditor.project.clips, recoveringEditor.project.clips, "autosave recovers unsaved cuts")
equal(resumedEditor.projectURL, namedProject, "recovery retains the named project's save destination")
check(resumedEditor.hasUnsavedChanges, "recovered unsaved edits remain marked as changed")
resumedEditor.newProject()
check(resumedEditor.items.isEmpty && resumedEditor.projectURL == nil, "new project starts with an empty timeline")
resumedEditor.undoEdit()
equal(resumedEditor.projectURL, namedProject, "undoing New Project restores the previous save destination")

// Editing an exported item must make it exportable again without breaking queue cleanup.
let queueEditor = AppModel(recoveryURL: nil)
queueEditor.restore(roundTripProject)
queueEditor.items[0].status = .done(editedOut)
queueEditor.clearFinished()
check(queueEditor.items.isEmpty, "Clear Done removes the selected completed item")
queueEditor.undoEdit()
check(queueEditor.items.count == 1, "undo restores a cleared item")
queueEditor.items[0].status = .done(editedOut)
var changedSettings = queueEditor.settings; changedSettings.quality = 50
queueEditor.updateSettings(changedSettings)
equal(queueEditor.convertibleCount, 1, "changing export settings makes completed edits exportable again")
let historyCount = queueEditor.undoEntries.count
queueEditor.updateCrop(queueEditor.selectedItem!.crop!)
equal(queueEditor.undoEntries.count, historyCount, "an unchanged crop does not create a spurious undo step")

var combinedClip = nativeMarker
combinedClip.segments = [TimelineSegment(start: 1, end: 3), TimelineSegment(start: 0, end: 0.5)]
let combinedOut = scratch.appendingPathComponent("combined-edit.mp4")
try await FFmpeg.export(input: markerClip, output: combinedOut, info: markerInfo, crop: combinedClip.crop!,
    regions: [CGRect(x: 0, y: 0, width: 100, height: 100)], zoomShots: combinedClip.zoomShots,
    segments: combinedClip.segments, settings: ExportSettings()) { _ in }
equal(try await frameCount(combinedOut), 75, "cuts, complex blur and zoom compose without changing frame count")
let combinedBox = try await markerBox(combinedOut, at: 1.5, size: CGSize(width: 1000, height: 600))
check(combinedBox != nil && parityBox != nil && abs(combinedBox!.midX - parityBox!.midX) < 5,
      "zoom remains correctly positioned after timeline assembly and blur")

var numericRateProject = roundTripProject
numericRateProject.clips[0].info?.fpsExpression = "30"
try numericRateProject.validate()
check(true, "project accepts the numeric fallback frame rate")
let zoomEditor = AppModel(recoveryURL: nil)
zoomEditor.restore(roundTripProject)
let resizingShot = zoomEditor.selectedItem!.zoomShots[0]
zoomEditor.setZoomHold(resizingShot.id, 100)
equal(zoomEditor.selectedItem!.zoomShots[0].start, resizingShot.start, "resizing a zoom keeps its start fixed")
check(abs(zoomEditor.selectedItem!.zoomShots[0].end - zoomEditor.selectedItem!.editedDuration) < 0.001,
      "resizing a zoom clamps its end to the edited duration")

print("\nMulti-recording movies")
let movieItems = [nativeClip, combinedClip]
let moviePlan = try MoviePlan(items: movieItems, movieSettings: MovieSettings(), settings: ExportSettings())
equal(moviePlan.size, CGSize(width: 320, height: 180), "movie canvas follows its first cropped recording")
check(abs(moviePlan.duration - 3.8) < 0.001, "movie duration includes cuts from every recording")
let movieFile = scratch.appendingPathComponent("multi-recording.mp4")
try await FFmpeg.exportMovie(plan: moviePlan, settings: ExportSettings(), output: movieFile) { _ in }
let movieInfo = try await FFmpeg.probe(url: movieFile)
equal(movieInfo.width, 320, "movie export fits differing dimensions onto one canvas")
check(abs(movieInfo.duration - 3.8) < 0.08, "assembled movie duration matches retained footage", "\(movieInfo.duration)")
equal(try await frameCount(movieFile), 114, "movie export retains the expected frame count")
let movieFirst = try await pixel(movieFile, x: 100, y: 80, at: 0.1)
check(movieFirst.2 > 200 && movieFirst.0 < 40, "movie starts with the first clip's edited section")
check(abs(try await toneFrequency(movieFile, at: 0.1) - 1320) < 15, "movie retains reordered source audio")
let moviePlayer = try await PlaybackController.makeMovieItem(moviePlan, settings: ExportSettings())
let movieGenerator = AVAssetImageGenerator(asset: moviePlayer.asset)
movieGenerator.videoComposition = moviePlayer.videoComposition
let movieFrame = try await movieGenerator.image(at: CMTime(seconds: 0.1, preferredTimescale: 600)).image
let moviePreviewFirst = nativePixel(movieFrame, x: 100, y: 80)
check(moviePreviewFirst.2 > 200 && moviePreviewFirst.0 < 40, "movie native preview starts with the same edited section")
let secondMovieFrame = try await movieGenerator.image(at: CMTime(seconds: 2.8, preferredTimescale: 600)).image
let movieFrameURL = scratch.appendingPathComponent("movie-native.png")
try NSBitmapImageRep(cgImage: secondMovieFrame).representation(using: .png, properties: [:])!.write(to: movieFrameURL)
let movieNativeBox = try await markerBox(movieFrameURL, at: 0, size: moviePlan.size)
let movieExportBox = try await markerBox(movieFile, at: 2.8, size: moviePlan.size)
check(movieNativeBox != nil && movieExportBox != nil && abs(movieNativeBox!.midX - movieExportBox!.midX) < 4 && abs(movieNativeBox!.midY - movieExportBox!.midY) < 4,
      "movie native preview matches scaled crop and zoom across sources", "native \(String(describing: movieNativeBox)), export \(String(describing: movieExportBox))")
let silentData = try await Shell.run(ffmpeg, ["-v", "error", "-ss", "2", "-i", movieFile.path, "-t", "0.2", "-vn", "-f", "s16le", "-ac", "1", "-"])
check(!silentData.stdout.isEmpty && silentData.stdout.allSatisfy { $0 == 0 }, "silent recordings receive a silent movie audio track")

var movieGIFSettings = ExportSettings(); movieGIFSettings.format = .gif
let movieGIF = scratch.appendingPathComponent("multi.gif")
try await FFmpeg.exportMovie(plan: moviePlan, settings: movieGIFSettings, output: movieGIF) { _ in }
check(abs(try await frameCount(movieGIF) - 57) <= 1, "multi-clip GIF uses a shared palette and edited duration")
var firstSilentSettings = ExportSettings(); firstSilentSettings.audio = .copy
let silentFirstPlan = try MoviePlan(items: [combinedClip, nativeClip], movieSettings: MovieSettings(), settings: firstSilentSettings)
let silentFirstMovie = scratch.appendingPathComponent("silent-first.mp4")
try await FFmpeg.exportMovie(plan: silentFirstPlan, settings: firstSilentSettings, output: silentFirstMovie) { _ in }
equal(try await FFmpeg.probe(url: silentFirstMovie).audioCodec, "aac", "audio survives when the first recording is silent and Copy is selected")

if let rotated {
    var portraitClip = VideoItem(url: rotated)
    portraitClip.info = try await FFmpeg.probe(url: rotated)
    portraitClip.crop = portraitClip.info!.fullFrame
    portraitClip.segments = [TimelineSegment(start: 0, end: 0.6)]
    let rotationPlan = try MoviePlan(items: [nativeClip, portraitClip], movieSettings: MovieSettings(), settings: ExportSettings())
    let rotationMovie = scratch.appendingPathComponent("rotation-movie.mp4")
    try await FFmpeg.exportMovie(plan: rotationPlan, settings: ExportSettings(), output: rotationMovie) { _ in }
    let rotationPlayer = try await PlaybackController.makeMovieItem(rotationPlan, settings: ExportSettings())
    let generator = AVAssetImageGenerator(asset: rotationPlayer.asset)
    generator.videoComposition = rotationPlayer.videoComposition
    let frame = try await generator.image(at: CMTime(seconds: 1.6, preferredTimescale: 600)).image
    let side = nativePixel(frame, x: 10, y: 90)
    check(side.0 < 10 && side.1 < 10 && side.2 < 10, "movie preview letterboxes a portrait recording")
    var difference = 0
    for point in [(130, 30), (155, 60), (180, 90), (140, 140)] {
        let a = nativePixel(frame, x: point.0, y: point.1)
        let b = try await pixel(rotationMovie, x: point.0, y: point.1, at: 1.6)
        difference += abs(a.0 - b.0) + abs(a.1 - b.1) + abs(a.2 - b.2)
    }
    check(difference < 300, "movie preview rotation matches exported portrait footage", "summed RGB difference \(difference)")
}
let movieEditor = AppModel(recoveryURL: nil)
movieEditor.restore(VideoProject(clips: movieItems.map(ProjectClip.init), settings: ExportSettings(), selection: nativeClip.id))
movieEditor.moveMovieClip(nativeClip.id, by: 1)
equal(movieEditor.items.first!.id, combinedClip.id, "movie recording order is editable")
movieEditor.undoEdit()
equal(movieEditor.items.first!.id, nativeClip.id, "undo restores movie recording order")
movieEditor.includeInMovie(nativeClip.id, included: false)
equal(try movieEditor.moviePlan().clips.count, 1, "excluded recordings remain editable but leave the movie")
let movieSaved = try JSONDecoder().decode(VideoProject.self, from: JSONEncoder().encode(movieEditor.project))
check(movieSaved.clips[0].includedInMovie == false, "project saves movie inclusion choices")

print("\nAssisted zooms and mixed frame rates")
let still = [UInt8](repeating: 70, count: ZoomAnalyzer.width * ZoomAnalyzer.height)
var active = still
for y in 30..<40 { for x in 120..<130 { active[y * ZoomAnalyzer.width + x] = 220 } }
check(ZoomAnalyzer.activity(previous: still, current: still) == nil, "static frames produce no zoom suggestion")
check(ZoomAnalyzer.activity(previous: still, current: [UInt8](repeating: 220, count: still.count)) == nil,
      "whole-screen changes are not mistaken for a zoom target")
let activity = ZoomAnalyzer.activity(previous: still, current: active)
check(activity != nil && abs(activity!.point.x - 0.78125) < 0.01 && abs(activity!.point.y - 0.3889) < 0.01,
      "localized activity yields the correct normalized target")
var analysisClip = VideoItem(url: markerClip)
analysisClip.info = markerInfo
var analysisFrames = Data()
for i in 0..<6 { analysisFrames.append(contentsOf: i == 2 ? active : still) }
let proposed = ZoomAnalyzer.proposals(frames: analysisFrames, rate: 2, clip: analysisClip)
equal(proposed.count, 1, "nearby activity events merge into one non-overlapping zoom")
if let proposal = proposed.first {
    check(proposal.shot.end <= analysisClip.editedDuration, "suggested zoom fits the edited duration")
    analysisClip.zoomShots = [proposal.shot]
    check(ZoomAnalyzer.proposals(frames: analysisFrames, rate: 2, clip: analysisClip).isEmpty,
          "suggestions respect existing manual zooms")
}
analysisClip.zoomShots = []
analysisClip.crop = CGRect(x: 0, y: 0, width: 200, height: 200)
check(ZoomAnalyzer.proposals(frames: analysisFrames, rate: 2, clip: analysisClip).isEmpty,
      "activity outside the crop is ignored")
analysisClip.crop = nil
analysisClip.segments = [TimelineSegment(start: 0, end: 0.9), TimelineSegment(start: 1.6, end: 3)]
check(ZoomAnalyzer.proposals(frames: analysisFrames, rate: 2, clip: analysisClip).isEmpty,
      "activity in removed footage is ignored")

let activityFile = scratch.appendingPathComponent("activity.mp4")
let activityResult = try await Shell.run(ffmpeg, ["-v", "error", "-y", "-f", "lavfi", "-i",
    "color=c=gray:s=320x180:r=24:d=4,drawbox=x=240:y=60:w=20:h=20:color=white:t=fill:enable='between(t,1,2)'",
    "-c:v", "libx264", "-pix_fmt", "yuv420p", activityFile.path])
equal(activityResult.status, 0, "created a localized activity fixture at 24 fps")
var activityClip = VideoItem(url: activityFile)
activityClip.info = try await FFmpeg.probe(url: activityFile)
let detected = try await ZoomAnalyzer.analyze(activityClip)
check(!detected.isEmpty, "local FFmpeg analysis produces a reviewable zoom suggestion")
let suggestionEditor = AppModel(recoveryURL: nil)
suggestionEditor.restore(VideoProject(clips: [ProjectClip(activityClip)], settings: ExportSettings(), selection: activityClip.id))
suggestionEditor.zoomSuggestions = detected
suggestionEditor.zoomSuggestionTimeline = suggestionEditor.items[0].timeline
suggestionEditor.applyZoomSuggestions()
equal(suggestionEditor.items[0].zoomShots.count, detected.count, "selected suggestions become ordinary editable zooms")
suggestionEditor.undoEdit()
check(suggestionEditor.items[0].zoomShots.isEmpty, "one undo removes the applied suggestions")
suggestionEditor.setPreviewFraction(0.5)
suggestionEditor.splitAtPlayhead()
suggestionEditor.zoomSuggestions = detected
suggestionEditor.applyZoomSuggestions()
check(suggestionEditor.items[0].zoomShots.isEmpty, "suggestions made before a recut are refused, not misplaced")
activityClip.zoomShots = detected.map(\.shot)
var mixedSettings = ExportSettings(); mixedSettings.audio = .none
let mixedPlan = try MoviePlan(items: [nativeClip, activityClip], movieSettings: MovieSettings(), settings: mixedSettings)
let mixedFile = scratch.appendingPathComponent("mixed-rate.mp4")
try await FFmpeg.exportMovie(plan: mixedPlan, settings: mixedSettings, output: mixedFile) { _ in }
equal(try await frameCount(mixedFile), 159, "24 fps footage with zoom normalizes to 30 fps without changing speed")
let mixedInfo = try await FFmpeg.probe(url: mixedFile)
check(abs(mixedInfo.duration - 5.3) < 0.04 && !mixedInfo.hasAudio, "mixed-rate silent movie keeps its planned duration")
let portraitPlan = try MoviePlan(items: movieItems, movieSettings: MovieSettings(canvas: .portrait), settings: ExportSettings())
equal(portraitPlan.size, CGSize(width: 1080, height: 1920), "portrait movie canvas is available")

let protectedOutput = scratch.appendingPathComponent("protected-movie.mp4")
let originalOutput = Data("existing export must survive cancellation".utf8)
try originalOutput.write(to: protectedOutput)
movieEditor.startMovieExport(plan: moviePlan, output: protectedOutput)
movieEditor.cancelConversion()
await movieEditor.movieExportTask?.value
equal(try Data(contentsOf: protectedOutput), originalOutput, "cancelling a movie export preserves an existing destination")
let sourceAlias = scratch.appendingPathComponent("source-alias.mp4")
try FileManager.default.createSymbolicLink(at: sourceAlias, withDestinationURL: nativeClip.url)
movieEditor.startMovieExport(plan: moviePlan, output: sourceAlias)
check(!movieEditor.isConverting, "movie export refuses a symlink to a source recording")

print("\nSpeed, waveform and silence cleanup")
let speedSegments = [TimelineSegment(start: 2, end: 3, speed: 2), TimelineSegment(start: 0, end: 1, speed: 0.5)]
var speedTimeline = ClipTimeline(segments: speedSegments)
check(abs(speedTimeline.duration - 2.5) < 0.00001, "section speeds determine edited duration")
check(abs(speedTimeline.location(at: 0.25)!.source - 2.5) < 0.00001, "fast section maps timeline time to the right source frame")
check(abs(speedTimeline.time(forSource: 0.5)! - 1.5) < 0.00001, "slow section maps source frames back to timeline time")
let rightSpeedID = speedTimeline.split(at: 1.5, fps: 30)
check(rightSpeedID != nil && speedTimeline.segments.last!.speed == 0.5, "splitting a retimed section preserves speed")
check(abs(speedTimeline.duration - 2.5) < 0.00001, "splitting retimed footage preserves duration")
let legacySection = Data("{\"id\":\"\(UUID().uuidString)\",\"start\":0,\"end\":1}".utf8)
equal(try JSONDecoder().decode(TimelineSegment.self, from: legacySection).speed, 1, "older projects default to normal speed")
let speedEditor = AppModel(recoveryURL: nil)
speedEditor.restore(VideoProject(clips: [ProjectClip(nativeClip)], settings: ExportSettings(), selection: nativeClip.id))
speedEditor.setSegmentSpeed(speedEditor.items[0].timeline.segments[0].id, speed: 2)
equal(speedEditor.project.version, VideoProject.currentVersion,
      "projects with speed edits are written at the current version, never downgraded")
let speedSaved = try JSONDecoder().decode(VideoProject.self, from: JSONEncoder().encode(speedEditor.project))
try speedSaved.validate()
equal(speedSaved.clips[0].segments![0].speed, 2, "project round trip retains section speed")
speedEditor.undoEdit()
equal(speedEditor.items[0].timeline.segments[0].speed, 1, "undo restores the previous speed")
var invalidSpeed = speedSaved
invalidSpeed.clips[0].segments![0].speed = 0
check((try? invalidSpeed.validate()) == nil, "invalid project speeds are rejected")

var speedClip = nativeClip; speedClip.segments = speedSegments
let speedOutput = scratch.appendingPathComponent("speed.mp4")
try await FFmpeg.export(input: colorSource, output: speedOutput, info: colorInfo, crop: colorInfo.fullFrame,
                        segments: speedSegments, settings: ExportSettings()) { _ in }
equal(try await frameCount(speedOutput), 75, "fast and slow sections export the expected frame count")
check(abs(try await FFmpeg.probe(url: speedOutput).duration - 2.5) < 0.05, "speed export audio and video end together")
let speedRed = try await pixel(speedOutput, x: 100, y: 80, at: 0.65)
check(speedRed.0 > 200 && speedRed.2 < 40, "retimed export cuts to the next section at the new boundary")
check(abs(try await toneFrequency(speedOutput, at: 0.1) - 1320) < 25, "speeding up audio preserves pitch")
check(abs(try await toneFrequency(speedOutput, at: 1.3) - 440) < 20, "slowing down audio preserves pitch")
let speedPlayer = try await PlaybackController.makeItem(speedClip, settings: ExportSettings())
check(abs(try await speedPlayer.asset.load(.duration).seconds - 2.5) < 0.001, "native playback uses the same retimed duration")
let speedGenerator = AVAssetImageGenerator(asset: speedPlayer.asset)
speedGenerator.videoComposition = speedPlayer.videoComposition
let speedNative = try await speedGenerator.image(at: CMTime(seconds: 0.65, preferredTimescale: 600)).image
let speedNativePixel = nativePixel(speedNative, x: 100, y: 80)
check(speedNativePixel.0 > 200 && speedNativePixel.2 < 40, "native playback cuts at the retimed export boundary")
let audioReader = try AVAssetReader(asset: speedPlayer.asset)
let speedAudioTracks = try await speedPlayer.asset.loadTracks(withMediaType: .audio)
let audioReaderOutput = AVAssetReaderAudioMixOutput(audioTracks: speedAudioTracks, audioSettings: [
    AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 8000, AVNumberOfChannelsKey: 1,
    AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false])
audioReaderOutput.audioMix = speedPlayer.audioMix
audioReader.add(audioReaderOutput)
check(audioReader.startReading(), "native retimed audio can be decoded")
var nativeAudio = Data()
while let sample = audioReaderOutput.copyNextSampleBuffer() {
    if let buffer = CMSampleBufferGetDataBuffer(sample) {
        var bytes = [UInt8](repeating: 0, count: CMBlockBufferGetDataLength(buffer))
        CMBlockBufferCopyDataBytes(buffer, atOffset: 0, dataLength: bytes.count, destination: &bytes)
        nativeAudio.append(contentsOf: bytes)
    }
}
check(audioReader.status == .completed && abs(Double(nativeAudio.count) / 16000 - 2.5) < 0.05, "native audio matches the retimed movie length")
let nativeSamples = nativeAudio.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
let pitchRange = Array(nativeSamples.dropFirst(9600).prefix(1600))
let crossings = zip(pitchRange, pitchRange.dropFirst()).filter { $0 <= 0 && $1 > 0 }.count
check(abs(Double(crossings) * 8000 / Double(max(1, pitchRange.count)) - 440) < 25, "native slowed audio preserves pitch too")

var speedMarker = nativeMarker
speedMarker.segments = [TimelineSegment(start: 0, end: 3, speed: 2)]
speedMarker.zoomShots = [ZoomShot(start: 0, hold: 0.5, level: 2, target: CGPoint(x: 930, y: 530))]
let speedMoviePlan = try MoviePlan(items: [speedClip, speedMarker], movieSettings: MovieSettings(), settings: ExportSettings())
let speedMovieFile = scratch.appendingPathComponent("speed-movie.mp4")
try await FFmpeg.exportMovie(plan: speedMoviePlan, settings: ExportSettings(), output: speedMovieFile) { _ in }
equal(try await frameCount(speedMovieFile), 120, "movie assembly combines speed edits and zoom without duration drift")
var speedGIFSettings = ExportSettings(); speedGIFSettings.format = .gif
let speedGIFFile = scratch.appendingPathComponent("speed.gif")
try await FFmpeg.export(input: markerClip, output: speedGIFFile, info: markerInfo, crop: speedMarker.crop!,
    zoomShots: speedMarker.zoomShots, segments: speedMarker.segments, settings: speedGIFSettings) { _ in }
check(abs(try await frameCount(speedGIFFile) - 23) <= 1, "GIF frame thinning remains correct after speed and zoom")

let pauseFile = scratch.appendingPathComponent("pauses.mp4")
let pauseResult = try await Shell.run(ffmpeg, ["-v", "error", "-y", "-f", "lavfi", "-i", "testsrc2=s=320x180:r=30:d=6",
    "-f", "lavfi", "-i", "aevalsrc='if(between(t,2,4),0,0.3*sin(2*PI*440*t))':s=48000:d=6",
    "-c:v", "libx264", "-c:a", "aac", "-shortest", pauseFile.path])
equal(pauseResult.status, 0, "created speech-like audio with a known two-second pause")
let overview = try await AudioAnalyzer.analyze(pauseFile)
check(overview.levels.count >= 119 && overview.levels.count <= 121, "streamed waveform includes the complete audio timeline")
check(overview.levels.filter { $0.time > 0.2 && $0.time < 1.8 }.allSatisfy { $0.decibels > -25 }, "waveform detects audible sections")
check(overview.levels.filter { $0.time > 2.2 && $0.time < 3.8 }.allSatisfy { $0.decibels < -60 }, "waveform detects the silent middle section")
var pauseClip = VideoItem(url: pauseFile); pauseClip.info = try await FFmpeg.probe(url: pauseFile)
let pauseCuts = overview.cuts(in: pauseClip.timeline, fps: 30, threshold: -40, minimum: 0.8, padding: 0.15)
equal(pauseCuts.count, 1, "silence review proposes the known pause")
if let cut = pauseCuts.first {
    check(cut.start >= 2.1 && cut.end <= 3.9, "silence cuts retain padding on both sides of speech")
    let cleaned = pauseClip.timeline.removing(pauseCuts)
    equal(cleaned.segments.count, 2, "applying a silence cut creates two retained sections")
    check(abs(cleaned.duration + cut.duration - 6) < 0.001, "removed silence has the exact reported duration")
    let cleanupEditor = AppModel(recoveryURL: nil)
    cleanupEditor.restore(VideoProject(clips: [ProjectClip(pauseClip)], settings: ExportSettings(), selection: pauseClip.id))
    cleanupEditor.commitTimeline(cleaned, name: "Remove Silence", selection: cleaned.segments.first?.id)
    cleanupEditor.undoEdit()
    equal(cleanupEditor.items[0].timeline.duration, 6, "one undo restores all proposed silence cuts")
    var excluded = pauseCuts; excluded[0].included = false
    equal(pauseClip.timeline.removing(excluded), pauseClip.timeline, "unchecked cuts leave the timeline unchanged")
    let retimedPauses = ClipTimeline(segments: [TimelineSegment(start: 0, end: 6, speed: 2)])
    let retimedCuts = overview.cuts(in: retimedPauses, fps: 30, threshold: -40, minimum: 0.8, padding: 0.15)
    check(abs(retimedCuts[0].duration * 2 - cut.duration) < 0.001, "silence savings reflect section speed")
    equal(retimedPauses.removing(retimedCuts).segments.last!.speed, 2, "silence removal preserves retained section speeds")
    check(overview.cuts(in: cleaned, fps: 30, threshold: -40, minimum: 0.8, padding: 0.15).isEmpty,
          "removed pauses are not suggested again")
}
let stereoFile = scratch.appendingPathComponent("opposite-phase.wav")
_ = try await Shell.run(ffmpeg, ["-v", "error", "-y", "-f", "lavfi", "-i",
    "aevalsrc='0.3*sin(2*PI*440*t)|-0.3*sin(2*PI*440*t)':s=48000:d=1", stereoFile.path])
let stereoOverview = try await AudioAnalyzer.analyze(stereoFile)
check(stereoOverview.levels.allSatisfy { $0.decibels > -25 }, "opposite-phase stereo is not incorrectly classified as silence")

// Many fractional frame boundaries must round cumulatively instead of drifting.
let fractionalSections = (0..<30).map { i in
    TimelineSegment(start: Double(i) / 10, end: Double(i + 1) / 10, speed: 1.25)
}
let fractionalOutput = scratch.appendingPathComponent("fractional-speed.mp4")
try await FFmpeg.export(input: colorSource, output: fractionalOutput, info: colorInfo, crop: colorInfo.fullFrame,
    segments: fractionalSections, settings: ExportSettings()) { _ in }
equal(try await frameCount(fractionalOutput), 72, "thirty fractional-frame speed sections do not accumulate duration drift")
check(abs(try await FFmpeg.probe(url: fractionalOutput).duration - 2.4) < 0.04, "many speed edits keep the audio and video clocks aligned")
var tinyTimeline = ClipTimeline(segments: [TimelineSegment(start: 0, end: 0.2, speed: 4)])
check(tinyTimeline.split(at: 0.025, fps: 30) == nil, "splitting cannot create a section shorter than one output frame")
for extreme in [0.25, 4.0] {
    let extremeOutput = scratch.appendingPathComponent("speed-\(extreme).mp4")
    try await FFmpeg.export(input: colorSource, output: extremeOutput, info: colorInfo, crop: colorInfo.fullFrame,
        segments: [TimelineSegment(start: 0, end: 1, speed: extreme)], settings: ExportSettings()) { _ in }
    check(abs(Double(try await frameCount(extremeOutput)) - 30 / extreme) <= 0.5, "\(extreme)× speed produces the expected duration")
}

print("\n\(checks - failures)/\(checks) checks passed")
try? FileManager.default.removeItem(at: scratch)
exit(failures == 0 ? 0 : 1)
