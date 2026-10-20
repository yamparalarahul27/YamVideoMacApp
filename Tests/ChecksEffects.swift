// Checks for effects. Run with ./test.sh effects
import AppKit
import AVFoundation
import Foundation

@MainActor func effectsTests() async throws {
    // MARK: - Whole-frame blur

    print("\nBlur effect timing")
    let timed = VideoBlurEffect(start: 1, end: 2, fadeIn: 0.25, fadeOut: 0.25)
    equal(timed.weight(at: 0.99), 0, "no blur before the effect starts")
    equal(timed.weight(at: 1), 0, "it starts from nothing")
    check(abs(timed.weight(at: 1.125) - 0.5) < 0.000001, "and is half in at the middle of its fade")
    equal(timed.weight(at: 1.5), 1, "full through the hold")
    check(timed.weight(at: 1.99) > 0 && timed.weight(at: 1.99) < 0.01, "almost gone just before the end")
    equal(timed.weight(at: 2), 0, "and gone at the end, which belongs to whatever follows")
    var hardEdged = timed; hardEdged.fadeIn = 0; hardEdged.fadeOut = 0
    check(hardEdged.weight(at: 1) == 1 && hardEdged.weight(at: 1.999) == 1 && hardEdged.weight(at: 2) == 0,
          "zero fades switch cleanly without dividing by zero")
    var halfMix = timed; halfMix.mix = 0.5
    equal(halfMix.weight(at: 1.5), 0.5, "mix scales the hold")
    var switchedOff = timed; switchedOff.isEnabled = false
    check(switchedOff.weight(at: 1.5) == 0 && !switchedOff.isVisible, "a switched-off effect draws nothing")
    var noAmount = timed; noAmount.amount = 0
    check(!noAmount.isVisible, "nor does one with no amount")
    check(abs(timed.sigma(for: CGSize(width: 1920, height: 1080)) - 24 * 1920 / 1080) < 0.000001,
          "strength scales with the frame's long side")
    for fps in [24.0, 30.0, 30000.0 / 1001.0] {
        let snapped = VideoBlurEffect(start: 1.01, end: 2.37).snapped(fps: fps)
        let onFrames = [snapped.start, snapped.end].allSatisfy { abs(($0 * fps).rounded() - $0 * fps) < 0.000001 }
        check(onFrames, "times snap to whole frames at \(String(format: "%.3f", fps)) fps")
    }
    check(VideoBlurEffect(start: 1, end: 1.01).problem(duration: 10, fps: 30) != nil, "an effect shorter than a frame is refused")
    check(VideoBlurEffect(start: 1, end: 1.4, fadeIn: 0.25, fadeOut: 0.25).problem(duration: 10, fps: 30) != nil,
          "fades that do not fit are refused")
    check(VideoBlurEffect(start: 9, end: 10.5).problem(duration: 10, fps: 30) != nil, "an effect past the end is refused")
    var badAmount = timed; badAmount.amount = 81
    check(badAmount.problem(duration: 10, fps: 30) != nil, "an amount above 80 is refused")
    var badMix = timed; badMix.mix = .nan
    check(badMix.problem(duration: 10, fps: 30) != nil, "a non-finite mix is refused")

    print("\nBlur effects follow the footage")
    let effectTimeline = ClipTimeline(segments: [TimelineSegment(start: 0, end: 4), TimelineSegment(start: 4, end: 8)])
    let earlyBlur = VideoBlurEffect(start: 1, end: 3), lateBlur = VideoBlurEffect(start: 5, end: 7)
    var splitEffects = effectTimeline
    _ = splitEffects.split(at: 2, fps: 30)
    equal(splitEffects.remap([earlyBlur, lateBlur], from: effectTimeline, fps: 30).map(\.start), [1, 5],
          "a split that keeps every frame leaves effects where they were")
    let withoutFirst = ClipTimeline(segments: [effectTimeline.segments[1]])
    equal(withoutFirst.remap([earlyBlur, lateBlur], from: effectTimeline, fps: 30).map(\.id), [lateBlur.id],
          "deleting the footage an effect starts on removes it")
    equal(withoutFirst.remap([lateBlur], from: effectTimeline, fps: 30).first?.start, 1, "and the rest move with their footage")
    var faster = effectTimeline; faster.segments[1].speed = 2
    let sped = faster.remap([VideoBlurEffect(start: 5, end: 5.6, fadeIn: 0.1, fadeOut: 0.1)], from: effectTimeline, fps: 30).first
    check(sped.map { abs($0.start - 4.5) < 0.000001 && abs($0.duration - 0.6) < 0.000001 } == true,
          "a speed change moves the start with its frame and keeps the duration in seconds")
    // Three sections; moving the last into the middle lands its effect inside one that
    // already runs across that cut.
    let threeParts = ClipTimeline(segments: [TimelineSegment(start: 0, end: 2), TimelineSegment(start: 2, end: 4), TimelineSegment(start: 4, end: 6)])
    let longFirst = VideoBlurEffect(start: 1, end: 3.5), lateShort = VideoBlurEffect(start: 4.5, end: 5.5)
    let middleMoved = ClipTimeline(segments: [threeParts.segments[0], threeParts.segments[2], threeParts.segments[1]])
    let collided = middleMoved.remap([longFirst, lateShort], from: threeParts, fps: 30)
    equal(collided.map(\.id), [longFirst.id], "a reorder that makes two effects collide keeps the earlier one")
    var shortTimeline = ClipTimeline(segments: [TimelineSegment(start: 0, end: 1.2)])
    let squeezed = shortTimeline.remap([VideoBlurEffect(start: 0.5, end: 2, fadeIn: 0.5, fadeOut: 0.5)],
                                       from: ClipTimeline(segments: [TimelineSegment(start: 0, end: 3)]), fps: 30).first
    check(squeezed.map { abs($0.end - 1.2) < 0.000001 && abs($0.fadeIn + $0.fadeOut - $0.duration) < 0.000001 } == true,
          "an effect cut short ends with the recording and its fades shrink to fit")
    shortTimeline = ClipTimeline(segments: [TimelineSegment(start: 0, end: 4)])
    let marked = [TimelineMarker(time: 1), TimelineMarker(time: 5), TimelineMarker(time: 8)]
    equal(ClipTimeline(segments: [effectTimeline.segments[1]]).remap(marked, from: effectTimeline).map(\.time), [1, 4],
          "markers follow their frames, go with removed footage, and the very end stays the end")

    print("\nBlur effect rendering")
    // A fine checkerboard, whose contrast says how blurred a frame is, beside two flat
    // colours meeting at a hard edge, whose profile says what shape the blur is.
    let fxWidth = 1280, fxHeight = 720
    var fxBytes = Data(capacity: fxWidth * fxHeight * 6)
    for y in 0..<fxHeight {
        for x in 0..<fxWidth {
            let color: SIMD3<Double> = x < 640 ? SIMD3(repeating: (x / 2 + y / 2) % 2 == 0 ? 0.1 : 0.9)
                : x < 960 ? SIMD3(0.8, 0.15, 0.1) : SIMD3(0.1, 0.25, 0.8)
            for channel in [color.x, color.y, color.z] {
                let value = UInt16((channel * 65535).rounded())
                fxBytes.append(UInt8(value & 0xFF)); fxBytes.append(UInt8(value >> 8))
            }
        }
    }
    let fxRaw = colorScratch.appendingPathComponent("fx.rgb48")
    try fxBytes.write(to: fxRaw)
    let fxSource = colorScratch.appendingPathComponent("fx.mov")
    let fxEncode = try await Shell.run(ffmpeg, ["-hide_banner", "-loglevel", "error", "-y",
        "-stream_loop", "-1", "-f", "rawvideo", "-pix_fmt", "rgb48le", "-s", "\(fxWidth)x\(fxHeight)", "-r", "30", "-i", fxRaw.path,
        "-t", "3", "-vf", "scale=out_color_matrix=bt709:out_range=tv:flags=accurate_rnd+full_chroma_int,format=yuv444p10le",
        "-c:v", "prores_ks", "-profile:v", "4444", "-color_primaries", "bt709", "-color_trc", "bt709",
        "-colorspace", "bt709", "-color_range", "tv", fxSource.path])
    check(fxEncode.status == 0, "made a checkerboard-and-edge test clip", fxEncode.stderrText)
    let fxInfo = try await FFmpeg.probe(url: fxSource)
    var fxItem = VideoItem(url: fxSource); fxItem.info = fxInfo; fxItem.crop = fxInfo.fullFrame
    fxItem.blurEffects = [timed]

    func fxFFmpegFrame(_ frameNumber: Int, effects: [VideoBlurEffect]) async throws -> RGBFrame {
        let stage = try FFmpeg.effectStage(effects, frame: fxInfo.fullFrame.size, fps: 30, matrix: "bt709", fullRange: false)
        let graph = FFmpeg.filterGraph(regions: [], style: .blur, strength: 1, tail: [], effects: stage,
                                       delivery: ["select='eq(n,\(frameNumber))'",
                                                  "scale=in_color_matrix=bt709:in_range=tv:out_range=pc:flags=accurate_rnd+full_chroma_int,format=rgb48le"])!
        let result = try await Shell.run(ffmpeg, ["-hide_banner", "-loglevel", "error", "-i", fxSource.path,
                                                  "-filter_complex", graph.spec, "-map", "[\(graph.outputLabel!)]",
                                                  "-frames:v", "1", "-f", "rawvideo", "-"])
        let words = result.stdout.withUnsafeBytes { Array($0.bindMemory(to: UInt16.self)) }
        return RGBFrame(width: fxWidth, height: fxHeight, values: words.map { Double(UInt16(littleEndian: $0)) / 65535 })
    }
    func fxNativeFrame(_ frameNumber: Int, item: VideoItem) async throws -> RGBFrame {
        let player = try await PlaybackController.makeItem(item, settings: ExportSettings())
        let generator = AVAssetImageGenerator(asset: player.asset)
        generator.videoComposition = player.videoComposition
        generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
        let image = try await generator.image(at: CMTime(value: CMTimeValue(frameNumber), timescale: 30)).image
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
    /// Luma standard deviation over the checkerboard's centre, where the blur's own edge
    /// handling cannot reach.
    func checkerContrast(_ frame: RGBFrame) -> Double {
        var lumas: [Double] = []
        for y in 260..<460 { for x in 200..<440 {
            let i = (y * frame.width + x) * 3
            lumas.append(0.2126 * frame.values[i] + 0.7152 * frame.values[i + 1] + 0.0722 * frame.values[i + 2])
        } }
        let mean = lumas.reduce(0, +) / Double(lumas.count)
        return (lumas.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(lumas.count)).squareRoot()
    }
    var plainFxItem = fxItem; plainFxItem.blurEffects = []
    let sharpContrast = checkerContrast(try await fxNativeFrame(45, item: plainFxItem))
    let ffmpegHold = try await fxFFmpegFrame(45, effects: [timed])
    let nativeHold = try await fxNativeFrame(45, item: fxItem)
    let ffmpegHoldContrast = checkerContrast(ffmpegHold), nativeHoldContrast = checkerContrast(nativeHold)
    check(ffmpegHoldContrast < 0.25 * sharpContrast && nativeHoldContrast < 0.25 * sharpContrast,
          "at full strength the blur removes most of the fine detail in both renderers",
          String(format: "ffmpeg %.4f, native %.4f, sharp %.4f", ffmpegHoldContrast, nativeHoldContrast, sharpContrast))

    // The weight each frame shows, read back from how much checkerboard survives, against
    // the weight the timing maths says it should have. Covers the frame before the start,
    // the start, the fades, the hold, the last frame and the end.
    var timingErrors: [String] = []
    for frame in [29, 30, 31, 33, 35, 37, 38, 45, 52, 54, 56, 59, 60, 61] {
        let expected = timed.weight(at: Double(frame) / 30)
        let shownFFmpeg = 1 - checkerContrast(try await fxFFmpegFrame(frame, effects: [timed])) / sharpContrast
        let shownNative = 1 - checkerContrast(try await fxNativeFrame(frame, item: fxItem)) / sharpContrast
        if abs(shownFFmpeg - expected) > 0.06 || abs(shownNative - expected) > 0.06 {
            timingErrors.append(String(format: "frame %d: expected %.2f, ffmpeg %.2f, native %.2f", frame, expected, shownFFmpeg, shownNative))
        }
    }
    check(timingErrors.isEmpty, "both renderers fade in and out on the same frames as the timing maths",
          timingErrors.joined(separator: "; "))

    // Shape: the profile across the hard colour edge, and the frame's own left edge.
    func row(_ frame: RGBFrame, y: Int, _ xs: Range<Int>) -> [SIMD3<Double>] {
        xs.map { x in let i = (y * frame.width + x) * 3; return SIMD3(frame.values[i], frame.values[i + 1], frame.values[i + 2]) }
    }
    let edgeNative = row(nativeHold, y: 360, 880..<1040), edgeFFmpeg = row(ffmpegHold, y: 360, 880..<1040)
    let edgeError = zip(edgeNative, edgeFFmpeg).map { abs($0 - $1).max() * 255 }.max() ?? 0
    check(edgeError <= 8, "the blur has the same shape across a hard edge in both renderers",
          String(format: "worst %.1f of 255", edgeError))
    let borderNative = row(nativeHold, y: 360, 0..<24), borderFFmpeg = row(ffmpegHold, y: 360, 0..<24)
    let borderError = zip(borderNative, borderFFmpeg).map { abs($0 - $1).max() * 255 }.max() ?? 0
    check(borderError <= 8, "and the frame's own edge gets no dark or bright halo in either",
          String(format: "worst %.1f of 255", borderError))
    print(String(format: "       blur at hold: sharp %.4f, ffmpeg %.4f, native %.4f; edge %.1f, border %.1f of 255",
                 sharpContrast, ffmpegHoldContrast, nativeHoldContrast, edgeError, borderError))

    print("\nEditing blur effects and markers")
    @MainActor func effectEditor() -> AppModel {
        let model = AppModel(recoveryURL: nil)
        var item = VideoItem(url: fxSource); item.info = fxInfo; item.crop = fxInfo.fullFrame
        model.restore(VideoProject(clips: [ProjectClip(item)], settings: ExportSettings(), selection: item.id))
        return model
    }
    let effecting = effectEditor()
    let effectClip = effecting.items[0].id
    effecting.setPreviewFraction(0.5 / 3)
    effecting.addBlurEffect()
    let added = effecting.items[0].blurEffects.first
    check(added.map { abs($0.start - 0.5) < 0.000001 && abs($0.end - 3) < 0.000001 } == true,
          "Add Blur Effect runs from the playhead for three seconds, or to the end", "\(String(describing: added))")
    check(effecting.selectedEffectID == added?.id && effecting.inspectorFocus == .effect, "and selects the new effect")
    equal(effecting.undoTitle, "Undo Add Blur Effect", "as one named step")
    effecting.addBlurEffect()
    check(effecting.items[0].blurEffects.count == 1 && effecting.statusMessage?.contains("no room") == true,
          "Add inside an effect would start where it ends; with no room left it changes nothing and says so",
          effecting.statusMessage ?? "")
    check(effecting.perform([.addBlurEffect(clip: effectClip, effect: VideoBlurEffect(start: 1, end: 2))]).isFailure,
          "an overlapping effect is refused")
    let shortEffect = VideoBlurEffect(start: 0, end: 0.4, fadeIn: 0.1, fadeOut: 0.1)
    effecting.perform([.addBlurEffect(clip: effectClip, effect: shortEffect)])
    let stored = effecting.items[0].blurEffects
    check(stored.count == 2 && stored[0].id == shortEffect.id, "two effects can touch, and are kept in time order")
    // The UI's clamps: a move stops at the neighbour, a fade shrinks to fit.
    effecting.updateEffect(added!.id) { $0.start = 0.1; $0.end = 2.6 }
    check(effecting.items[0].blurEffects.last.map { abs($0.start - 0.4) < 0.000001 && abs($0.duration - 2.5) < 0.000001 } == true,
          "dragging an effect into its neighbour stops at it", "\(effecting.items[0].blurEffects)")
    effecting.updateEffect(added!.id) { $0.fadeIn = 10 }
    let fadeFit = effecting.items[0].blurEffects.last!
    check(abs(fadeFit.fadeIn + fadeFit.fadeOut - fadeFit.duration) < 0.000001, "a fade longer than the effect is shortened to fit")
    let sliderSteps = effecting.undoEntries.count
    for amount in [30.0, 40, 50] { effecting.updateEffect(added!.id, live: true) { $0.amount = amount } }
    effecting.endGesture()
    check(effecting.undoEntries.count == sliderSteps + 1 && effecting.items[0].blurEffects.last?.amount == 50,
          "an amount drag is one undo step")
    effecting.selectedEffectID = added!.id
    effecting.toggleSelectedEffect()
    check(effecting.items[0].blurEffects.last?.isEnabled == false, "an effect can be switched off without deleting it")
    effecting.removeSelectedEffect()
    check(effecting.items[0].blurEffects.count == 1 && effecting.selectedEffectID == nil, "and deleted")

    effecting.setPreviewFraction(1.0 / 3)
    effecting.addMarkerAtPlayhead()
    effecting.setPreviewFraction(2.0 / 3)
    effecting.addMarkerAtPlayhead()
    effecting.addMarkerAtPlayhead()
    equal(effecting.items[0].markers.count, 2, "M adds a marker at the playhead, once per frame")
    effecting.updateMarker(effecting.items[0].markers[0].id) { $0.label = "Intro ends\nhere"; $0.color = .green }
    check(effecting.items[0].markers[0].label == "Intro endshere" && effecting.items[0].markers[0].color == .green,
          "a marker can be named and coloured, on one line")
    effecting.setPreviewFraction(0)
    effecting.jumpToMarker(forward: true)
    check(abs(effecting.previewTime - 1) < 0.02, "⇧↓ jumps to the next marker")
    effecting.jumpToMarker(forward: true)
    check(abs(effecting.previewTime - 2) < 0.02, "and on to the one after")
    effecting.jumpToMarker(forward: true)
    check(abs(effecting.previewTime - 2) < 0.02 && effecting.statusMessage?.contains("No marker after") == true,
          "stopping at the last rather than wrapping")
    effecting.jumpToMarker(forward: false)
    check(abs(effecting.previewTime - 1) < 0.02, "⇧↑ jumps back")
    check(effecting.perform([.addMarker(clip: effectClip, marker: TimelineMarker(time: 99))]).isFailure, "a marker past the end is refused")
    let roundTripEffects = try JSONDecoder().decode(VideoProject.self, from: JSONEncoder().encode(effecting.project))
    check(roundTripEffects == effecting.project && roundTripEffects.version == VideoProject.currentVersion, "effects and markers survive a project round trip")
    var olderWithEffects = roundTripEffects; olderWithEffects.version = 4
    check((try? olderWithEffects.validate()) == nil, "a version 4 file carrying effects or markers is refused")
    effecting.perform([.splitSection(clip: effectClip, at: 1.5)])
    let splitSections = effecting.items[0].timeline.segments
    if case .success(let cut) = effecting.perform([.deleteSection(clip: effectClip, section: splitSections[0].id)]) {
        check(cut.removedMarkers.count == 1 && effecting.items[0].markers.count == 1
                  && abs(effecting.items[0].markers[0].time - 0.5) < 0.02,
              "cutting footage removes the markers on it and moves the rest with theirs")
    } else { check(false, "cutting footage removes the markers on it and moves the rest with theirs") }

    print("\nBlur effects and markers for agents")
    let catalog = AgentCatalog.current
    let wireFields = Set(Mirror(reflecting: WireCommand(type: "x")).children.compactMap(\.label))
    equal(Set(catalog.commands.map(\.type)), Set(WireCommand.types), "the catalog describes exactly the commands apply accepts")
    let unknownFields = catalog.commands.flatMap { command in command.fields.map(\.name).filter { !wireFields.contains($0) }.map { "\(command.type).\($0)" } }
    check(unknownFields.isEmpty, "every field it names is one apply reads", unknownFields.joined(separator: ", "))
    var badExamples: [String] = []
    for command in catalog.commands {
        guard let data = try? JSONEncoder().encode(command.example),
              let wire = try? JSONDecoder().decode(WireCommand.self, from: data), wire.type == command.type,
              case .object(let keys) = command.example, Set(keys.keys).isSubset(of: wireFields) else { badExamples.append(command.type); continue }
    }
    check(badExamples.isEmpty, "every example is a well-formed command of its own type", badExamples.joined(separator: ", "))
    check(catalog.commands.allSatisfy { !$0.summary.isEmpty && $0.fields.allSatisfy { !$0.description.isEmpty } },
          "and every command and field says what it is for")
    equal(Set(catalog.methods.map(\.method)), Set(AppModel.agentMethods), "the catalog describes every request method")
    let served = agentResult(await agentCall(effectEditor(), ["method": "catalog"]))
    check((served["commands"] as? [Any])?.count == catalog.commands.count && (served["conventions"] as? [Any])?.isEmpty == false,
          "and agents can ask the app for it")

    let fxAgent = effectEditor()
    let fxClipID = fxAgent.items[0].id.uuidString
    let fxEffectID = UUID(), fxMarkerID = UUID()
    var fxApply = address(fxAgent)
    fxApply["method"] = "apply"; fxApply["requestID"] = "fx-1"; fxApply["client"] = "Codex"; fxApply["label"] = "Blur the middle"
    fxApply["commands"] = [["type": "addBlurEffect", "clipID": fxClipID, "start": 1, "duration": 1, "effectID": fxEffectID.uuidString],
                           ["type": "addMarker", "clipID": fxClipID, "time": 1.5, "label": "Blurred here", "color": "purple",
                            "markerID": fxMarkerID.uuidString]]
    let fxApplied = await agentCall(fxAgent, fxApply)
    let fxEffect = fxAgent.items[0].blurEffects.first
    check(fxApplied["ok"] as? Bool == true && fxEffect?.id == fxEffectID && fxEffect?.end == 2
              && fxEffect?.fadeIn == 0.25 && fxAgent.items[0].markers.first?.label == "Blurred here",
          "an agent can add an effect and a marker with its own ids in one step", "\(fxApplied)")
    check(fxAgent.agentHighlight?.elements.isSuperset(of: [fxEffectID, fxMarkerID]) == true,
          "and the owner sees both highlighted")
    var fxUpdate = address(fxAgent)
    fxUpdate["method"] = "apply"; fxUpdate["requestID"] = "fx-2"
    fxUpdate["commands"] = [["type": "updateBlurEffect", "clipID": fxClipID, "effectID": fxEffectID.uuidString, "mix": 0.5, "start": 1.5]]
    _ = await agentCall(fxAgent, fxUpdate)
    check(fxAgent.items[0].blurEffects.first.map { $0.mix == 0.5 && $0.start == 1.5 && $0.end == 2.5 } == true,
          "moving an effect's start keeps its length")
    var fxBad = address(fxAgent)
    fxBad["method"] = "apply"; fxBad["requestID"] = "fx-3"
    fxBad["commands"] = [["type": "updateBlurEffect", "clipID": fxClipID, "effectID": fxEffectID.uuidString, "fadeIn": 0.8, "fadeOut": 0.8]]
    let fxBadAnswer = await agentCall(fxAgent, fxBad)
    check(agentError(fxBadAnswer) == "invalid_command"
              && ((fxBadAnswer["error"] as? [String: Any])?["message"] as? String)?.contains("must fit") == true,
          "fades that do not fit are refused with a reason an agent can act on")
    let fxState = (agentResult(await agentCall(fxAgent, ["method": "state"]))["clips"] as? [[String: Any]])?.first
    check((fxState?["blurEffects"] as? [[String: Any]])?.first?["mix"] as? Double == 0.5
              && (fxState?["markers"] as? [[String: Any]])?.first?["color"] as? String == "purple",
          "state lists effects and markers with their settings")
    let composedHold = agentResult(await agentCall(fxAgent, ["method": "preview", "clip": fxClipID, "time": 2, "composed": true]))
    let composedClear = agentResult(await agentCall(fxAgent, ["method": "preview", "clip": fxClipID, "time": 0.5, "composed": true]))
    func previewContrast(_ result: [String: Any]) -> Double {
        guard let path = result["path"] as? String, let image = NSImage(contentsOfFile: path) else { return -1 }
        return checkerContrast(thumbFrame(image))
    }
    check(composedHold["composed"] as? Bool == true && composedHold["width"] as? Int == fxWidth,
          "a composed preview is the picture at the export's frame size")
    let holdDetail = previewContrast(composedHold), clearDetail = previewContrast(composedClear)
    check(holdDetail >= 0 && holdDetail < 0.5 * clearDetail,
          "and shows the effect where it runs and not where it does not", String(format: "%.3f vs %.3f", holdDetail, clearDetail))
    _ = await agentCall(fxAgent, ["method": "reveal", "clip": fxClipID, "effect": fxEffectID.uuidString])
    check(fxAgent.selectedEffectID == fxEffectID && fxAgent.pictureEdit == nil, "reveal shows the owner an effect, in the player")

    print("\nBlur effects in exports")
    var fxExportItem = fxAgent.items[0]
    fxExportItem.blurEffects = [VideoBlurEffect(start: 1, end: 2)]
    let fxWith = colorScratch.appendingPathComponent("fx-with.mp4"), fxWithout = colorScratch.appendingPathComponent("fx-without.mp4")
    try await FFmpeg.export(input: fxSource, output: fxWith, info: fxInfo, crop: fxInfo.fullFrame, settings: ExportSettings(),
                            effects: fxExportItem.blurEffects) { _ in }
    try await FFmpeg.export(input: fxSource, output: fxWithout, info: fxInfo, crop: fxInfo.fullFrame, settings: ExportSettings()) { _ in }
    equal(try await frameCount(fxWith), try await frameCount(fxWithout), "an effect never changes the frame count")
    func exportedContrast(_ url: URL, at time: Double) async throws -> Double {
        let result = try await Shell.run(ffmpeg, ["-hide_banner", "-loglevel", "error", "-ss", String(format: "%.3f", time), "-i", url.path,
                                                  "-frames:v", "1", "-vf", "scale=in_color_matrix=bt709:in_range=tv:out_range=pc,format=rgb48le",
                                                  "-f", "rawvideo", "-"])
        let words = result.stdout.withUnsafeBytes { Array($0.bindMemory(to: UInt16.self)) }
        return checkerContrast(RGBFrame(width: fxWidth, height: fxHeight, values: words.map { Double(UInt16(littleEndian: $0)) / 65535 }))
    }
    let exportSharp = try await exportedContrast(fxWith, at: 0.5), exportBlurred = try await exportedContrast(fxWith, at: 1.5)
    check(exportBlurred < 0.25 * exportSharp, "the exported MP4 is blurred during the effect and sharp outside it",
          String(format: "%.3f vs %.3f", exportBlurred, exportSharp))
    var fxGIF = ExportSettings(); fxGIF.format = .gif
    let fxGIFCommands = FFmpeg.exportCommands(input: fxSource, output: colorScratch.appendingPathComponent("fx.gif"), info: fxInfo,
                                              crop: fxInfo.fullFrame, settings: fxGIF, effects: fxExportItem.blurEffects)
    check(fxGIFCommands.count == 2 && fxGIFCommands.allSatisfy { $0.joined(separator: " ").contains("gblur=sigma") },
          "both GIF passes get the effect, so the palette is built for the picture written")
    // A movie where the affected recording is second: its effect is timed from its own start.
    var firstInMovie = gradeOther; firstInMovie.includedInMovie = true
    let fxMoviePlan = try MoviePlan(items: [firstInMovie, fxExportItem], movieSettings: MovieSettings(canvas: .widescreen), settings: ExportSettings())
    let fxMovieArgs = FFmpeg.movieArguments(plan: fxMoviePlan, settings: ExportSettings(), output: colorScratch.appendingPathComponent("fxm.mp4"))
    check(fxMovieArgs.joined(separator: " ").contains("blend@fx1_0"), "a movie names each recording's effect filters apart")
    let fxMovie = colorScratch.appendingPathComponent("fx-movie.mp4")
    try await FFmpeg.exportMovie(plan: fxMoviePlan, settings: ExportSettings(), output: fxMovie) { _ in }
    let secondStart = fxMoviePlan.offset(of: fxExportItem.id)
    func movieDetail(_ time: Double) async throws -> Double {
        let result = try await Shell.run(ffmpeg, ["-hide_banner", "-loglevel", "error", "-ss", String(format: "%.3f", time), "-i", fxMovie.path,
                                                  "-frames:v", "1", "-vf", "scale=1280:720,format=gray", "-f", "rawvideo", "-"])
        let bytes = [UInt8](result.stdout)
        var values: [Double] = []
        for y in 260..<460 { for x in 200..<440 { values.append(Double(bytes[y * 1280 + x]) / 255) } }
        let mean = values.reduce(0, +) / Double(values.count)
        return (values.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(values.count)).squareRoot()
    }
    let movieSharp = try await movieDetail(secondStart + 0.5), movieBlurred = try await movieDetail(secondStart + 1.5)
    check(movieBlurred < 0.25 * movieSharp, "in a movie the second recording's blur starts at its own one second",
          String(format: "%.3f at its 1.5 s vs %.3f at its 0.5 s", movieBlurred, movieSharp))

    var hdrFxInfo = fxInfo; hdrFxInfo.colorTransfer = "arib-std-b67"
    var keepHDR = ExportSettings(); keepHDR.toneMapHDR = false
    check(FFmpeg.effectProblem([VideoBlurEffect(start: 1, end: 2)], info: hdrFxInfo, settings: keepHDR) != nil
              && FFmpeg.effectProblem([VideoBlurEffect(start: 1, end: 2)], info: hdrFxInfo, settings: ExportSettings()) == nil,
          "an effect on HDR kept as HDR is refused, not exported mislabelled; tone-mapped it is fine")

}
