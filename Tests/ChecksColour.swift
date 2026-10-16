// Checks for colour. Run with ./test.sh colour
import AppKit
import AVFoundation
import Foundation

@MainActor func colourTests() async throws {
    // MARK: - Colour

    print("\nColour tables")
    let colorScratch = scratch.appendingPathComponent("colour", isDirectory: true)
    try FileManager.default.createDirectory(at: colorScratch, withIntermediateDirectories: true)
    setenv("YAMVIDEO_LUT_STORE", colorScratch.appendingPathComponent("store").path, 1)
    check(LUTStore.directory.path == colorScratch.appendingPathComponent("store").path,
          "the tests keep their own table store", LUTStore.directory.path)


    // The file order is red fastest, then green, then blue, and line endings vary.
    let tinyIdentity = "TITLE \"tiny\"\r\nLUT_3D_SIZE 2\r\n# a comment\r\n0 0 0\r\n1 0 0\r\n0 1 0\r\n1 1 0\r\n0 0 1\r\n1 0 1\r\n0 1 1\r\n1 1 1\r\n"
    equal(try ColorCube.parse(Data(tinyIdentity.utf8)), ColorCube.identity(size: 2), "a 2³ identity with CRLF endings and a comment reads as identity")
    equal(try ColorCube.parse(Data(tinyIdentity.replacingOccurrences(of: "\r\n", with: "\r").utf8)), ColorCube.identity(size: 2),
          "and so does one with old Mac line endings")
    let redOnly = ColorCube.build(size: 2) { SIMD3($0.x, 0, 0) }
    check(near(redOnly.sample(SIMD3(0.25, 0.5, 0.75)), SIMD3(0.25, 0, 0)), "a table that keeps red keeps red, not green or blue")
    let swapped = ColorCube.build(size: 9) { SIMD3($0.z, $0.x, $0.y) }
    check(near(swapped.sample(SIMD3(0.1, 0.2, 0.3)), SIMD3(0.3, 0.1, 0.2)), "channels land where the table puts them")
    check(near(ColorCube.identity(size: 17).sample(SIMD3(0.123, 0.456, 0.789)), SIMD3(0.123, 0.456, 0.789)),
          "trilinear sampling of an identity is the identity between grid points")
    check(near(ColorCube.identity(size: 5).sample(SIMD3(-0.4, 1.7, .nan)), SIMD3(0, 1, 0)), "inputs outside the domain clamp to its edge")
    let wideDomain = try ColorCube.parse(Data("LUT_3D_SIZE 2\nDOMAIN_MIN -1 -1 -1\nDOMAIN_MAX 3 3 3\n-1 -1 -1\n3 -1 -1\n-1 3 -1\n3 3 -1\n-1 -1 3\n3 -1 3\n-1 3 3\n3 3 3\n".utf8))
    check(near(wideDomain.sample(SIMD3(0.5, 2, -0.5)), SIMD3(0.5, 2, -0.5)), "a declared domain is honoured")
    check(near(wideDomain.unitDomain().sample(SIMD3(0.25, 0.5, 1)), SIMD3(0, 1, 3)),
          "and folded into a unit-domain table for Core Image")
    let curved = ColorCube.build(size: 7) { SIMD3(pow($0.x, 0.7), $0.y * $0.y, 0.2 + 0.6 * $0.z) }
    equal(try ColorCube.parse(Data(curved.cubeText(title: "round trip").utf8)), curved, "a table written for ffmpeg reads back unchanged")

    check(cubeRefusal("0 0 0\n") != nil, "a table without LUT_3D_SIZE is refused")
    check(cubeRefusal("LUT_3D_SIZE 1\n0 0 0\n") != nil, "so is a size below 2")
    check(cubeRefusal("LUT_3D_SIZE 66\n") != nil, "and one above 65")
    check(cubeRefusal("LUT_3D_SIZE 2\n0 0 0\n1 0 0\n") != nil, "an incomplete table is refused")
    check(cubeRefusal(tinyIdentity + "1 1 1\n") != nil, "and so is one with rows to spare")
    check(cubeRefusal(tinyIdentity.replacingOccurrences(of: "1 1 1", with: "1 nan 1")) != nil, "a non-finite entry is refused")
    check(cubeRefusal(tinyIdentity.replacingOccurrences(of: "1 1 1", with: "1 1")) != nil, "a row with two numbers is refused")
    check(cubeRefusal("LUT_1D_SIZE 4\n" + tinyIdentity) != nil, "a 1D table or shaper is refused rather than half-applied")
    check(cubeRefusal("LUT_3D_SIZE 2\nINCLUDE other.cube\n") != nil, "an unknown keyword is refused")
    check(cubeRefusal("LUT_3D_SIZE 2\n0 0 0\nDOMAIN_MIN 0 0 0\n") != nil, "a keyword inside the table is refused")
    check(cubeRefusal("LUT_3D_SIZE 2\nDOMAIN_MIN 1 0 0\nDOMAIN_MAX 1 1 1\n") != nil, "an empty domain is refused")
    check((try? ColorCube.parse(Data(count: ColorCube.maximumBytes + 1))) == nil, "a file over 16 MB is refused unread")

    print("\nColour adjustments")
    let neutralSamples = [SIMD3(0.0, 0.0, 0.0), SIMD3(0.18, 0.5, 0.9), SIMD3(1.0, 1.0, 1.0), SIMD3(0.03, 0.7, 0.42)]
    check(neutralSamples.allSatisfy { near(ColorAdjustments.neutral.apply($0), $0, 0.0000001) },
          "neutral adjustments return the input exactly")
    check(near(ColorAdjustments(exposureEV: 1).apply(SIMD3(repeating: 0.5)), SIMD3(repeating: 0.5 * pow(2, 1 / 2.4))),
          "one stop brighter doubles linear light through the 2.4 power")
    let warm = ColorAdjustments(warmth: 1).apply(SIMD3(repeating: 0.5))
    let warmLinear = SIMD3(ColorAdjustments.decode(warm.x), ColorAdjustments.decode(warm.y), ColorAdjustments.decode(warm.z))
    check(warm.x > warm.y && warm.y > warm.z, "warmth tips grey towards red and away from blue")
    check(abs((warmLinear * ColorAdjustments.luma).sum() - ColorAdjustments.decode(0.5)) < 0.000001,
          "without changing grey's luminance")
    let pivot = ColorAdjustments.encode(0.18)
    check(near(ColorAdjustments(contrast: 1.5).apply(SIMD3(repeating: pivot)), SIMD3(repeating: pivot)), "contrast pivots on 18% grey")
    let grey = ColorAdjustments(saturation: 0).apply(SIMD3(0.8, 0.3, 0.1))
    check(abs(grey.x - grey.y) < 0.000001 && abs(grey.y - grey.z) < 0.000001, "no colour strength leaves grey")

    var colorSettings = ClipColorSettings()
    check(colorSettings.isDefault && (try? colorSettings.validate()) != nil, "default colour settings are valid and untouched")
    colorSettings.exposureEV = 2.5
    check((try? colorSettings.validate()) == nil, "brightness beyond two stops is refused")
    colorSettings = ClipColorSettings(); colorSettings.saturation = .nan
    check((try? colorSettings.validate()) == nil, "a non-finite colour strength is refused")
    colorSettings = ClipColorSettings(); colorSettings.correctionEnabled = true
    check((try? colorSettings.validate()) == nil, "Natural colour without the conversion table is refused")
    let fakeRef = LUTAssetRef(sha256: String(repeating: "a", count: 64), originalName: "x.cube", role: .pocket3DLogMToRec709)
    colorSettings = ClipColorSettings(); colorSettings.technicalLUT = fakeRef
    check((try? colorSettings.validate()) == nil, "a D-Log M conversion on a recording not set to D-Log M is refused")
    colorSettings.inputProfile = .pocket3DLogM
    check((try? colorSettings.validate()) != nil, "and accepted once it is")
    colorSettings.algorithmVersion = 2
    check((try? colorSettings.validate()) == nil, "an algorithm this build does not know is refused")

    // What Auto may conclude. Only HDR tags count as proof; a DJI name asks instead.
    var taggedInfo = info
    taggedInfo.colorTransfer = "smpte2084"
    equal(taggedInfo.inferredColorProfile(fileName: "a.mov").profile, .pq, "Auto reads a PQ tag as PQ")
    taggedInfo.colorTransfer = "arib-std-b67"
    equal(taggedInfo.inferredColorProfile(fileName: "a.mov").profile, .hlg, "and an HLG tag as HLG")
    taggedInfo.colorTransfer = "bt709"
    check(taggedInfo.inferredColorProfile(fileName: "DJI_20261014_0001_D.MP4").profile == nil,
          "a DJI recording tagged Rec.709 is left for the owner to say, not assumed to be D-Log M")
    taggedInfo.cameraMake = "DJI"
    check(taggedInfo.inferredColorProfile(fileName: "clip.mp4").profile == nil, "and so is one whose metadata names DJI")
    taggedInfo.cameraMake = nil
    equal(taggedInfo.inferredColorProfile(fileName: "screen.mov").profile, .standard, "anything else is standard colour")
    var standardOnly = ClipColorSettings(); standardOnly.inputProfile = .pq
    check((try? standardOnly.validate(against: info)) == nil, "HDR cannot be chosen for a file not tagged HDR")
    var logOnHDR = ClipColorSettings(); logOnHDR.inputProfile = .pocket3DLogM
    taggedInfo.colorTransfer = "smpte2084"
    check((try? logOnHDR.validate(against: taggedInfo)) == nil, "D-Log M cannot be chosen for a file tagged HDR")

    print("\nColour stage")
    // A stand-in for a camera's log conversion: smooth, monotonic, and different per
    // channel, so a renderer that swaps axes or skips a transfer step shows up.
    let fakeConversion = ColorCube.build(size: 33) { p in
        func lift(_ x: Double) -> Double { 0.04 + 0.92 * x * x * (3 - 2 * x) }
        return SIMD3(lift(0.92 * p.x + 0.08 * p.y), lift(p.y), lift(0.85 * p.z + 0.15 * p.x))
    }
    let conversionFile = colorScratch.appendingPathComponent("Fake D-Log M to Rec709.cube")
    try Data(fakeConversion.cubeText(title: "fake").utf8).write(to: conversionFile)
    let conversion = try LUTStore.importTable(at: conversionFile, role: .pocket3DLogMToRec709)
    check(FileManager.default.fileExists(atPath: LUTStore.url(for: conversion.sha256).path), "an imported table is kept under its hash")
    equal(LUTStore.cube(conversion.sha256), fakeConversion, "and reads back as the same table")
    check(!LUTStore.isOfficial(conversion), "a table that is not DJI's is not called DJI's")
    let brokenCube = colorScratch.appendingPathComponent("broken.cube")
    try Data("LUT_3D_SIZE 2\n0 0 0\n".utf8).write(to: brokenCube)
    check((try? LUTStore.importTable(at: brokenCube, role: .pocket3DLogMToRec709)) == nil, "a malformed table is not imported")

    var stagedItem = VideoItem(url: landscape)
    stagedItem.info = info
    check(stagedItem.colorStage(ExportSettings()).render == nil && stagedItem.colorStage(ExportSettings()).problem == nil,
          "untouched standard footage has no colour stage at all")
    stagedItem.color.inputProfile = .pocket3DLogM
    check(stagedItem.colorStage(ExportSettings()).render == nil, "choosing D-Log M alone converts nothing until Natural colour is on")
    stagedItem.color.technicalLUT = LUTAssetRef(sha256: String(repeating: "b", count: 64), originalName: "gone.cube", role: .pocket3DLogMToRec709)
    stagedItem.color.correctionEnabled = true
    check(stagedItem.colorStage(ExportSettings()).problem?.contains("gone.cube") == true,
          "a missing conversion table is reported by name, not silently skipped")
    stagedItem.color.technicalLUT = conversion
    equal(stagedItem.colorStage(ExportSettings()).render?.cube, fakeConversion, "with the table present, Natural colour applies it as it is")
    stagedItem.color.adjustments = ColorAdjustments(exposureEV: 0.5, warmth: 0.3, contrast: 1.2, saturation: 1.3)
    let bakedStage = stagedItem.colorStage(ExportSettings())
    let baked = bakedStage.render!
    let gridPoint = SIMD3(Double(5) / 32, Double(20) / 32, Double(31) / 32)
    check(near(baked.cube.sample(gridPoint), stagedItem.color.adjustments.apply(fakeConversion.sample(gridPoint))
                .clamped(lowerBound: SIMD3(repeating: 0), upperBound: SIMD3(repeating: 1)), 0.000001),
          "adjustments are baked onto the conversion at its own grid points, clipped to 0–1")
    check(baked.cube.values.allSatisfy { (0...1).contains($0) }, "no compiled table carries a value outside 0–1")
    check(stagedItem.colorStage(ExportSettings()).render === baked, "the same settings reuse the compiled table")
    stagedItem.color.warmth = 0.31
    check(stagedItem.colorStage(ExportSettings()).render?.key != baked.key, "different settings compile a different table")
    check(stagedItem.colorStage(ExportSettings(), original: true).render == nil, "Original leaves the colour stage out")
    let colorFilters = try ColorPipeline.ffmpegFilters(bakedStage, info: info, toneMapped: false)
    check(colorFilters.count == 3 && colorFilters[0].contains("in_color_matrix=bt709") && colorFilters[1].contains("interp=trilinear")
          && colorFilters[2].contains("yuv420p10le"),
          "ffmpeg reads the source's own matrix, applies the table trilinearly and stays 10-bit", colorFilters.joined(separator: ","))
    var hdrStageItem = stagedItem
    hdrStageItem.info?.colorTransfer = "arib-std-b67"
    hdrStageItem.color = ClipColorSettings(); hdrStageItem.color.contrast = 1.2
    var passThrough = ExportSettings(); passThrough.toneMapHDR = false
    check(hdrStageItem.colorStage(passThrough).problem != nil, "adjusting HDR that is not tone-mapped is refused, not mislabelled")
    check(hdrStageItem.colorStage(ExportSettings()).render != nil, "and allowed once it is tone-mapped")
    check((try ColorPipeline.ffmpegFilters(hdrStageItem.colorStage(ExportSettings()), info: hdrStageItem.info!, toneMapped: true))
            .first?.contains("in_color_matrix=bt709:in_range=tv") == true,
          "after tone mapping the stage reads BT.709 limited range, whatever the source was")

    print("\nColour parity")
    // A 10-bit 4:4:4 chart of flat patches tagged Rec.709, so neither renderer has chroma
    // to guess and every patch centre is a known encoded colour.
    let chartWidth = chartColumns * patchWidth, chartHeight = chartRows * patchHeight
    var seed: UInt32 = 12345
    func nextValue() -> Double { seed = seed &* 1_664_525 &+ 1_013_904_223; return 0.03 + 0.94 * Double(seed >> 8) / Double(1 << 24) }
    var patchColors: [SIMD3<Double>] = (0..<chartColumns).map { SIMD3(repeating: 0.05 + 0.9 * Double($0) / Double(chartColumns - 1)) }
    patchColors += [SIMD3(0.78, 0.57, 0.45), SIMD3(0.55, 0.38, 0.29), SIMD3(0.92, 0.73, 0.62), SIMD3(0.36, 0.24, 0.18)]
    while patchColors.count < chartColumns * chartRows { patchColors.append(SIMD3(nextValue(), nextValue(), nextValue())) }
    var chartBytes = Data(capacity: chartWidth * chartHeight * 6)
    for y in 0..<chartHeight {
        for x in 0..<chartWidth {
            let color = patchColors[(y / patchHeight) * chartColumns + x / patchWidth]
            for channel in [color.x, color.y, color.z] {
                let value = UInt16((channel * 65535).rounded())
                chartBytes.append(UInt8(value & 0xFF)); chartBytes.append(UInt8(value >> 8))
            }
        }
    }
    let chartRaw = colorScratch.appendingPathComponent("chart.rgb48")
    try chartBytes.write(to: chartRaw)
    let chart = colorScratch.appendingPathComponent("chart.mov")
    let chartEncode = try await Shell.run(ffmpeg, ["-hide_banner", "-loglevel", "error", "-y",
        "-stream_loop", "-1", "-f", "rawvideo", "-pix_fmt", "rgb48le", "-s", "\(chartWidth)x\(chartHeight)", "-r", "30", "-i", chartRaw.path,
        "-t", "1", "-vf", "scale=out_color_matrix=bt709:out_range=tv:flags=accurate_rnd+full_chroma_int,format=yuv444p10le",
        "-c:v", "prores_ks", "-profile:v", "4444", "-color_primaries", "bt709", "-color_trc", "bt709",
        "-colorspace", "bt709", "-color_range", "tv", chart.path])
    check(chartEncode.status == 0, "made a 10-bit Rec.709 colour chart", chartEncode.stderrText)
    let chartInfo = try await FFmpeg.probe(url: chart)
    check(chartInfo.yuvMatrix == "bt709" && !chartInfo.isFullRange, "the chart probes as BT.709 limited range")

    /// Encoded Rec.709 RGB, 0–1, row-major from the top-left.
    func ffmpegFrame(_ head: [String]) async throws -> RGBFrame {
        let chain = head + ["scale=in_color_matrix=bt709:in_range=tv:out_range=pc:flags=accurate_rnd+full_chroma_int,format=rgb48le"]
        let result = try await Shell.run(ffmpeg, ["-hide_banner", "-loglevel", "error", "-ss", "0.5", "-i", chart.path,
                                                  "-frames:v", "1", "-vf", chain.joined(separator: ","), "-f", "rawvideo", "-"])
        let words = result.stdout.withUnsafeBytes { Array($0.bindMemory(to: UInt16.self)) }
        return RGBFrame(width: chartWidth, height: chartHeight, values: words.map { Double(UInt16(littleEndian: $0)) / 65535 })
    }
    func nativeFrame(_ item: VideoItem) async throws -> RGBFrame {
        let player = try await PlaybackController.makeItem(item, settings: ExportSettings())
        let generator = AVAssetImageGenerator(asset: player.asset)
        generator.videoComposition = player.videoComposition
        generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
        let image = try await generator.image(at: CMTime(seconds: 0.5, preferredTimescale: 600)).image
        // Read in the space macOS decoded the Rec.709 chart into, so the values are the
        // encoded ones a 709 file would carry, as ffmpeg's are.
        var words = [UInt16](repeating: 0, count: image.width * image.height * 4)
        let context = CGContext(data: &words, width: image.width, height: image.height, bitsPerComponent: 16,
                                bytesPerRow: image.width * 8, space: ColorPipeline.videoSpace,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        var values: [Double] = []; values.reserveCapacity(image.width * image.height * 3)
        for pixel in stride(from: 0, to: words.count, by: 4) {
            values += [Double(words[pixel]) / 65535, Double(words[pixel + 1]) / 65535, Double(words[pixel + 2]) / 65535]
        }
        return RGBFrame(width: image.width, height: image.height, values: values)
    }
    /// Mean and 99th percentile of the per-channel difference, in 8-bit code values.
    func errorStats(_ a: RGBFrame, _ b: (Int) -> [SIMD3<Double>]) -> (mean: Double, p99: Double) {
        var errors: [Double] = []
        for index in 0..<(chartColumns * chartRows) {
            for (pixel, expected) in zip(a.patch(index), b(index)) {
                errors += [abs(pixel.x - expected.x), abs(pixel.y - expected.y), abs(pixel.z - expected.z)].map { $0 * 255 }
            }
        }
        errors.sort()
        return (errors.reduce(0, +) / Double(errors.count), errors[Int(Double(errors.count - 1) * 0.99)])
    }
    func describe(_ stats: (mean: Double, p99: Double)) -> String { String(format: "mean %.2f, p99 %.2f of 255", stats.mean, stats.p99) }

    var chartItem = VideoItem(url: chart)
    chartItem.info = chartInfo; chartItem.crop = chartInfo.fullFrame
    let plainFFmpeg = try await ffmpegFrame([])
    let plainNative = try await nativeFrame(chartItem)
    let decodeStats = errorStats(plainNative) { plainFFmpeg.patch($0) }
    check(decodeStats.mean <= 2 && decodeStats.p99 <= 6, "both renderers decode the chart alike before any colour", describe(decodeStats))
    let sourceStats = errorStats(plainFFmpeg) { Array(repeating: patchColors[$0], count: plainFFmpeg.patch($0).count) }
    check(sourceStats.p99 <= 1, "and the chart decodes to the colours it was made from", describe(sourceStats))

    chartItem.color.inputProfile = .pocket3DLogM; chartItem.color.technicalLUT = conversion; chartItem.color.correctionEnabled = true
    chartItem.color.adjustments = ColorAdjustments(exposureEV: 0.5, warmth: 0.3, contrast: 1.2, saturation: 1.3)
    let chartStage = chartItem.colorStage(ExportSettings())
    let gradedFFmpeg = try await ffmpegFrame(try ColorPipeline.ffmpegFilters(chartStage, info: chartInfo, toneMapped: false))
    let gradedNative = try await nativeFrame(chartItem)
    let expectedGrade = { (index: Int) in
        Array(repeating: chartStage.render!.cube.sample(patchColors[index]),
              count: plainFFmpeg.patch(index).count)
    }
    let ffmpegGrade = errorStats(gradedFFmpeg, expectedGrade)
    let nativeGrade = errorStats(gradedNative, expectedGrade)
    let gradeParity = errorStats(gradedNative) { gradedFFmpeg.patch($0) }
    check(ffmpegGrade.mean <= 2 && ffmpegGrade.p99 <= 6, "ffmpeg applies the colour stage to the encoded values it should", describe(ffmpegGrade))
    check(nativeGrade.mean <= 2 && nativeGrade.p99 <= 6, "so does Core Image, with no extra transfer step", describe(nativeGrade))
    check(gradeParity.mean <= 2 && gradeParity.p99 <= 6, "and the two renderers agree within the release gate", describe(gradeParity))
    print("       colour parity: decode \(describe(decodeStats)); ffmpeg vs maths \(describe(ffmpegGrade)); native vs maths \(describe(nativeGrade)); native vs ffmpeg \(describe(gradeParity))")

    // The real DJI conversion, when the person running the suite points at a copy of it.
    if let djiPath = ProcessInfo.processInfo.environment["YAMVIDEO_DJI_LUT"], FileManager.default.fileExists(atPath: djiPath) {
        let dji = try LUTStore.importTable(at: URL(fileURLWithPath: djiPath), role: .pocket3DLogMToRec709)
        check(LUTStore.isOfficial(dji), "the supplied DJI table is DJI's official Pocket 3 conversion", dji.sha256)
        chartItem.color.technicalLUT = dji; chartItem.color.adjustments = .neutral
        let djiStage = chartItem.colorStage(ExportSettings())
        let djiFFmpeg = try await ffmpegFrame(try ColorPipeline.ffmpegFilters(djiStage, info: chartInfo, toneMapped: false))
        let djiNative = try await nativeFrame(chartItem)
        let djiParity = errorStats(djiNative) { djiFFmpeg.patch($0) }
        check(djiParity.mean <= 2 && djiParity.p99 <= 6, "with DJI's table the two renderers still agree", describe(djiParity))
        print("       DJI parity: \(describe(djiParity))")
    }

    print("\nColour commands")
    // Two probed recordings: the 10-bit chart and the landscape clip.
    var gradeChart = VideoItem(url: chart); gradeChart.info = chartInfo; gradeChart.crop = chartInfo.fullFrame
    @MainActor func colorEditor() -> AppModel {
        let model = AppModel(recoveryURL: nil)
        model.restore(VideoProject(clips: [ProjectClip(gradeChart), ProjectClip(gradeOther)], settings: ExportSettings(), selection: gradeChart.id))
        return model
    }
    let grading = colorEditor()
    @MainActor func gradingColor(_ index: Int = 0) -> ClipColorSettings { grading.items[index].color }

    check(grading.perform([.setColorCorrection(clip: gradeChart.id, enabled: true)]).isFailure,
          "Natural colour is refused before there is a conversion")
    check(grading.perform([.setTechnicalLUT(clip: gradeChart.id, lut: conversion)]).isFailure,
          "a conversion is refused while the recording is not set to D-Log M")
    let gradingSteps = grading.undoEntries.count
    grading.applyNaturalColor(conversion)
    check(gradingColor().inputProfile == .pocket3DLogM && gradingColor().technicalLUT == conversion && gradingColor().correctionEnabled,
          "Natural colour sets D-Log M, the conversion and the correction")
    check(grading.undoEntries.count == gradingSteps + 1 && grading.undoTitle == "Undo Natural Colour", "as one undoable step")
    check(grading.statusMessage?.contains("not DJI's official") == true, "and says when the conversion is not DJI's own")
    check(grading.items[0].colorStage(grading.settings).render != nil, "the recording now has a colour stage")

    let dragSteps = grading.undoEntries.count
    for value in [0.2, 0.4, 0.6] { grading.setColorAdjustments(ColorAdjustments(exposureEV: value), live: true) }
    equal(gradingColor().exposureEV, 0.6, "a brightness drag shows each value as it goes")
    equal(grading.undoEntries.count, dragSteps, "without an undo step per value")
    grading.endGesture()
    check(grading.undoEntries.count == dragSteps + 1 && grading.undoTitle == "Undo Adjust Colour", "and is one step when it ends")
    check(grading.perform([.setColorAdjustments(clip: gradeChart.id, exposureEV: 3, warmth: nil, contrast: nil, saturation: nil)]).isFailure
              && gradingColor().exposureEV == 0.6,
          "an out-of-range value is refused, never clamped")
    check(grading.perform([.setColorAdjustments(clip: gradeChart.id, exposureEV: nil, warmth: nil, contrast: nil, saturation: nil)]).isFailure,
          "an adjustment naming no control is refused")
    grading.perform([.setColorAdjustments(clip: gradeChart.id, exposureEV: nil, warmth: 0.5, contrast: nil, saturation: nil)])
    check(gradingColor().warmth == 0.5 && gradingColor().exposureEV == 0.6, "a partial adjustment leaves the other controls alone")

    grading.copyColor(to: [gradeOther.id], includeInterpretation: false)
    check(gradingColor(1).adjustments == gradingColor().adjustments && gradingColor(1).inputProfile == .auto
              && gradingColor(1).technicalLUT == nil,
          "copying colour copies the look, not how the footage was recorded")
    grading.undoEdit()
    grading.copyColor(to: [gradeOther.id], includeInterpretation: true)
    check(gradingColor(1).inputProfile == .pocket3DLogM && gradingColor(1).correctionEnabled, "unless asked to")
    var hdrProject = grading.project
    hdrProject.clips[1].info?.colorTransfer = "smpte2084"; hdrProject.clips[1].color = nil
    check((try? ProjectReducer.apply([.copyColor(from: gradeChart.id, to: [gradeOther.id], includeInterpretation: true)], to: hdrProject)) == nil,
          "and never onto a recording whose file rules D-Log M out")
    check((try? ProjectReducer.apply([.copyColor(from: gradeChart.id, to: [gradeChart.id], includeInterpretation: false)], to: grading.project)) == nil,
          "a recording cannot copy onto itself")

    grading.resetColorAdjustments()
    check(gradingColor().adjustments.isNeutral && gradingColor().correctionEnabled, "Reset Adjustments keeps Natural colour")
    grading.removeColorCorrection()
    check(!gradingColor().correctionEnabled && gradingColor().technicalLUT == conversion, "Remove Correction keeps the conversion to hand")
    grading.setInputProfile(.standard)
    check(gradingColor().technicalLUT == nil && !gradingColor().correctionEnabled, "a profile the conversion does not fit removes it")
    grading.setInputProfile(.auto)
    check(grading.project.clips[0].color == nil, "a recording back at the defaults stores no colour at all")

    grading.applyNaturalColor(conversion)
    grading.setColorAdjustments(ColorAdjustments(exposureEV: 0.25, warmth: -0.2, contrast: 1.1, saturation: 0.9))
    let gradedProject = try JSONDecoder().decode(VideoProject.self, from: JSONEncoder().encode(grading.project))
    check(gradedProject == grading.project && gradedProject.version == VideoProject.currentVersion, "colour survives a round trip")
    var olderWithColour = gradedProject; olderWithColour.version = 3
    check((try? olderWithColour.validate()) == nil, "a version 3 file carrying colour is refused")
    var unknownAlgorithm = gradedProject; unknownAlgorithm.clips[0].color?.algorithmVersion = 9
    check((try? unknownAlgorithm.validate()) == nil, "so is colour from an algorithm this build does not know")

    print("\nColour for agents")
    let colorAgent = colorEditor()
    let colorClip = gradeChart.id.uuidString
    let colorState = (agentResult(await agentCall(colorAgent, ["method": "state"]))["clips"] as? [[String: Any]])?.first?["color"] as? [String: Any]
    check(colorState?["inputProfile"] as? String == "auto" && colorState?["profileInEffect"] as? String == "standard"
              && colorState?["profileChosen"] as? Bool == false,
          "state says which profile is in effect and that it was inferred")
    var colorApply = address(colorAgent)
    colorApply["method"] = "apply"; colorApply["requestID"] = "colour-1"; colorApply["client"] = "Claude"; colorApply["label"] = "Correct the D-Log M"
    colorApply["commands"] = [["type": "setInputProfile", "clipID": colorClip, "profile": "pocket3DLogM"],
                              ["type": "importTechnicalLUT", "clipID": colorClip, "path": conversionFile.path],
                              ["type": "setColorCorrection", "clipID": colorClip, "enabled": true],
                              ["type": "setColorAdjustments", "clipID": colorClip, "warmth": 0.2]]
    let colorApplied = await agentCall(colorAgent, colorApply)
    check(colorApplied["ok"] as? Bool == true && colorAgent.items[0].color.correctionEnabled && colorAgent.items[0].color.warmth == 0.2,
          "an agent can set D-Log M, import the conversion, correct and adjust in one step", "\(colorApplied)")
    equal(colorAgent.undoTitle, "Undo Correct the D-Log M (Claude)", "and it is one named undo step")
    let agentColor = (agentResult(await agentCall(colorAgent, ["method": "state"]))["clips"] as? [[String: Any]])?.first?["color"] as? [String: Any]
    let agentConversion = agentColor?["conversion"] as? [String: Any]
    check(agentConversion?["sha256"] as? String == conversion.sha256 && agentConversion?["available"] as? Bool == true
              && agentConversion?["official"] as? Bool == false && agentColor?["profileChosen"] as? Bool == true,
          "state reports the conversion by hash, whether it is DJI's, and that this Mac has it")
    var badTable = address(colorAgent)
    badTable["method"] = "apply"; badTable["requestID"] = "colour-2"
    badTable["commands"] = [["type": "importTechnicalLUT", "clipID": colorClip, "path": brokenCube.path]]
    let badAnswer = await agentCall(colorAgent, badTable)
    check(agentError(badAnswer) == "invalid_command" && colorAgent.items[0].color.technicalLUT == conversion,
          "a malformed table from an agent changes nothing")
    var outOfRange = address(colorAgent)
    outOfRange["method"] = "apply"; outOfRange["requestID"] = "colour-3"
    outOfRange["commands"] = [["type": "setColorAdjustments", "clipID": colorClip, "saturation": 2.5]]
    equal(agentError(await agentCall(colorAgent, outOfRange)), "invalid_command", "an agent's out-of-range colour is refused")
    let pairTime = 0.5
    let correctedPreview = agentResult(await agentCall(colorAgent, ["method": "preview", "clip": colorClip, "time": pairTime]))
    let originalPreview = agentResult(await agentCall(colorAgent, ["method": "preview", "clip": colorClip, "time": pairTime, "original": true]))
    check(correctedPreview["revision"] as? Int == originalPreview["revision"] as? Int && originalPreview["original"] as? Bool == true
              && correctedPreview["original"] as? Bool == false,
          "an agent can ask for original and corrected previews at the same revision")
    if let correctedPath = correctedPreview["path"] as? String, let originalPath = originalPreview["path"] as? String {
        check((try? Data(contentsOf: URL(fileURLWithPath: correctedPath))) != (try? Data(contentsOf: URL(fileURLWithPath: originalPath))),
              "and the two differ")
    }

    print("\nColour with saved projects")
    let projectFolder = colorScratch.appendingPathComponent("projects", isDirectory: true)
    try FileManager.default.createDirectory(at: projectFolder, withIntermediateDirectories: true)
    let gradedFile = projectFolder.appendingPathComponent("Graded.yamvideo")
    grading.save(to: gradedFile, asCopy: false)
    let besideProject = LUTStore.projectURL(for: conversion.sha256, beside: gradedFile)
    check((try? Data(contentsOf: besideProject)).map(ColorCube.sha256) == conversion.sha256,
          "saving copies the conversion beside the project, under its hash")
    let homeStore = LUTStore.directory.path
    setenv("YAMVIDEO_LUT_STORE", colorScratch.appendingPathComponent("another-mac").path, 1)
    check(!LUTStore.has(conversion.sha256), "a Mac that never imported the table does not have it")
    let reopened = AppModel(recoveryURL: nil)
    reopened.openProject(at: gradedFile)
    check(LUTStore.has(conversion.sha256) && reopened.items[0].colorStage(reopened.settings).render != nil,
          "opening the project there takes the table from beside it", reopened.statusMessage ?? "")
    try FileManager.default.removeItem(at: besideProject.deletingLastPathComponent().deletingLastPathComponent())
    setenv("YAMVIDEO_LUT_STORE", colorScratch.appendingPathComponent("third-mac").path, 1)
    let stranded = AppModel(recoveryURL: nil)
    stranded.openProject(at: gradedFile)
    check(stranded.statusMessage?.contains("missing") == true && stranded.items[0].colorStage(stranded.settings).problem != nil,
          "with the table nowhere, opening says so and correction is held back, not dropped", stranded.statusMessage ?? "")
    var strandedExport = false
    do {
        try await FFmpeg.export(input: chart, output: colorScratch.appendingPathComponent("stranded.mp4"), info: chartInfo,
                                crop: chartInfo.fullFrame, settings: ExportSettings(),
                                color: stranded.items[0].colorStage(stranded.settings)) { _ in }
    } catch { strandedExport = error.localizedDescription.contains("missing") }
    check(strandedExport && !FileManager.default.fileExists(atPath: colorScratch.appendingPathComponent("stranded.mp4").path),
          "and an export refuses rather than writing uncorrected video")
    setenv("YAMVIDEO_LUT_STORE", homeStore, 1)

    print("\nColour in movies")
    var movieGraded = grading.items[0]
    var movieStandard = gradeOther
    let colourPlan = try MoviePlan(items: [movieGraded, movieStandard], movieSettings: MovieSettings(), settings: ExportSettings())
    let colourMovieArgs = FFmpeg.movieArguments(plan: colourPlan, settings: ExportSettings(), output: colorScratch.appendingPathComponent("m.mp4"))
    let colourGraph = colourMovieArgs[colourMovieArgs.firstIndex(of: "-filter_complex")! + 1]
    check(colourGraph.components(separatedBy: "lut3d").count == 2, "a movie applies colour only to the recording that has it")
    check(colourMovieArgs.contains("-color_primaries") && colourMovieArgs.contains("bt709"), "and is tagged Rec.709")
    movieStandard.info?.colorTransfer = "arib-std-b67"
    let hdrMovieArgs = FFmpeg.movieArguments(plan: try MoviePlan(items: [movieStandard], movieSettings: MovieSettings(), settings: ExportSettings()),
                                             settings: ExportSettings(), output: colorScratch.appendingPathComponent("h.mp4"))
    check(hdrMovieArgs.joined(separator: " ").contains("tonemap="), "an HDR recording in a movie is tone-mapped like its own export")

    // Movie preview gets half-float frames and writes Rec.709, so it matches too.
    movieGraded.color.adjustments = ColorAdjustments(exposureEV: 0.5, warmth: 0.3, contrast: 1.2, saturation: 1.3)
    let moviePlanGraded = try MoviePlan(items: [movieGraded], movieSettings: MovieSettings(), settings: ExportSettings())
    let movieItemGraded = try await PlaybackController.makeMovieItem(moviePlanGraded, settings: ExportSettings())
    let movieGrader = AVAssetImageGenerator(asset: movieItemGraded.asset)
    movieGrader.videoComposition = movieItemGraded.videoComposition
    movieGrader.requestedTimeToleranceBefore = .zero; movieGrader.requestedTimeToleranceAfter = .zero
    let colourMovieImage = try await movieGrader.image(at: CMTime(seconds: 0.5, preferredTimescale: 600)).image
    var movieWords = [UInt16](repeating: 0, count: colourMovieImage.width * colourMovieImage.height * 4)
    let movieContext = CGContext(data: &movieWords, width: colourMovieImage.width, height: colourMovieImage.height, bitsPerComponent: 16,
                                 bytesPerRow: colourMovieImage.width * 8, space: ColorPipeline.videoSpace,
                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue)!
    movieContext.draw(colourMovieImage, in: CGRect(x: 0, y: 0, width: colourMovieImage.width, height: colourMovieImage.height))
    var movieValues: [Double] = []
    for pixel in stride(from: 0, to: movieWords.count, by: 4) {
        movieValues += [Double(movieWords[pixel]) / 65535, Double(movieWords[pixel + 1]) / 65535, Double(movieWords[pixel + 2]) / 65535]
    }
    let colourMovieFrame = RGBFrame(width: colourMovieImage.width, height: colourMovieImage.height, values: movieValues)
    let movieStage = movieGraded.colorStage(ExportSettings())
    let movieExpected = { (index: Int) in Array(repeating: movieStage.render!.cube.sample(patchColors[index]), count: plainFFmpeg.patch(index).count) }
    let movieParity = errorStats(colourMovieFrame, movieExpected)
    check(colourMovieFrame.width == chartWidth && movieParity.mean <= 2 && movieParity.p99 <= 6,
          "movie preview colours the chart within the release gate", describe(movieParity))
    print("       movie preview vs maths: \(describe(movieParity))")

    print("\nFast colour preview")
    let plainThumb = NSImage(data: try await FFmpeg.thumbnail(url: chart, at: 0.5, duration: chartInfo.duration))!
    let exactThumb = NSImage(data: try await FFmpeg.thumbnail(url: chart, at: 0.5, duration: chartInfo.duration,
                                                              color: try ColorPipeline.ffmpegFilters(movieStage, info: chartInfo, toneMapped: false)))!
    let quickThumb = ColorPipeline.quickPreview(plainThumb, movieStage.render!)!
    let quickExact = thumbFrame(exactThumb)
    let quickStats = errorStats(thumbFrame(quickThumb)) { quickExact.patch($0) }
    check(quickStats.mean <= 2 && quickStats.p99 <= 6, "a slider's instant preview matches the exact frame that replaces it", describe(quickStats))
    print("       instant vs exact preview: \(describe(quickStats))")
    // The plan's target: slider feedback within 150 ms of a frame already on screen. Timed
    // on a 4K frame, the largest a Pocket 3 records, after one warm-up for the GPU.
    let fourK = NSImage(size: NSSize(width: 3840, height: 2160), flipped: false) { rect in
        NSColor(calibratedRed: 0.4, green: 0.5, blue: 0.3, alpha: 1).setFill(); rect.fill(); return true
    }
    let fourKBitmap = NSBitmapImageRep(data: fourK.tiffRepresentation!)!
    let fourKFrame = NSImage(size: fourK.size); fourKFrame.addRepresentation(fourKBitmap)
    _ = ColorPipeline.quickPreview(fourKFrame, movieStage.render!)
    let quickStart = Date()
    _ = ColorPipeline.quickPreview(fourKFrame, movieStage.render!)
    let quickMilliseconds = Date().timeIntervalSince(quickStart) * 1000
    check(quickMilliseconds < 150, "a slider's instant preview of a 4K frame takes under 150 ms", String(format: "%.0f ms", quickMilliseconds))
    print(String(format: "       instant preview, 4K frame: %.0f ms", quickMilliseconds))

}
