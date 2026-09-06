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
        "-color_trc", "arib-std-b67", "-colorspace", "bt2020nc", "-color_primaries", "bt2020",
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
    // text the pixels are identical and any difference really is the caption.
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
    let footBand = (y: frame.height * 7 / 8, height: frame.height / 8)

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

    // Lifting the caption should leave the very bottom of the frame alone. The bottom
    // eighth is used rather than the quarter so the check holds whichever reference
    // height libass ends up scaling the margin against.
    let plainFoot = try await bandLuma(plainFile, y: footBand.y, height: footBand.height, width: width)
    let bottomFoot = try await bandLuma(bottomFile, y: footBand.y, height: footBand.height, width: width)
    let liftedFoot = try await bandLuma(liftedFile, y: footBand.y, height: footBand.height, width: width)
    if let seated = meanDifference(plainFoot, bottomFoot),
       let lifted = meanDifference(plainFoot, liftedFoot) {
        check(lifted < seated,
              "the safe area lifts the caption out of the bottom of the frame",
              "bottom \(seated) vs lifted \(lifted)")
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

print("\n\(checks - failures)/\(checks) checks passed")
try? FileManager.default.removeItem(at: scratch)
exit(failures == 0 ? 0 : 1)
