import AppKit
import Foundation

/// Blur areas for part of a recording: BlurRegion's start and end in source seconds,
/// turned into edited-time spans (BlurBox) for the player and the export.
@MainActor func blurTests() async throws {
    print("\nTimed blur areas")
    func spans(_ value: [ClosedRange<Double>]?) -> [[Double]] {
        (value ?? []).map { [($0.lowerBound * 1000).rounded() / 1000, ($0.upperBound * 1000).rounded() / 1000] }
    }
    let rect = CGRect(x: 100, y: 60, width: 200, height: 120)
    let timed = BlurRegion(rect: rect, start: 1.0, end: 1.5)
    let plain = ClipTimeline(segments: [TimelineSegment(start: 0, end: 2)])
    check(BlurRegion(rect: rect).editedSpans(on: plain) == nil, "an area without times covers the whole recording")
    equal(spans(timed.editedSpans(on: plain)), [[0.9, 1.6]],
          "with no cuts, its range is the same in edited time, 0.1 s wider on each side")
    let cut = ClipTimeline(segments: [TimelineSegment(start: 0, end: 0.5), TimelineSegment(start: 1.2, end: 2)])
    equal(spans(timed.editedSpans(on: cut)), [[0.4, 0.9]], "a cut before it moves it with its footage")
    let fast = ClipTimeline(segments: [TimelineSegment(start: 0, end: 2, speed: 2)])
    equal(spans(timed.editedSpans(on: fast)), [[0.4, 0.85]], "a speed change moves it with its footage")
    let split = ClipTimeline(segments: [TimelineSegment(start: 0, end: 1.2), TimelineSegment(start: 1.2, end: 2)])
    equal(spans(timed.editedSpans(on: split)), [[0.9, 1.6]], "a split with nothing cut out keeps one span")
    check(BlurBox.boxes([timed], on: ClipTimeline(segments: [TimelineSegment(start: 0, end: 0.8)])).isEmpty,
          "an area whose whole range is cut out draws nothing")
    check(timed.covers(source: 1.2) && !timed.covers(source: 0.5) && !timed.covers(source: 1.7),
          "a frame's source time says whether the area covers it")
    let box = BlurBox(rect: rect, spans: [0.4...0.9])
    check(box.isOn(at: 0.5) && !box.isOn(at: 1.0) && BlurBox(rect: rect).isOn(at: 99),
          "the player draws a box only in its spans")
    equal(FFmpeg.enable([0.4...0.9]), ":enable='between(t,0.4000,0.9000)'", "the export limits a timed area with enable")
    equal(FFmpeg.enable(nil), "", "an untimed area needs no enable")
    if let black = FFmpeg.filterGraph(regions: [box], style: .black, strength: 20, tail: []) {
        check(black.spec.contains("drawbox=100:60:200:120:color=black:t=fill:enable='between(t,0.4000,0.9000)'"),
              "a black box is limited the same way", black.spec)
    } else { check(false, "a black box is limited the same way") }
    let saved = Data(#"{"id":"\#(UUID().uuidString)","rect":[[1,2],[30,40]]}"#.utf8)
    let old = try JSONDecoder().decode(BlurRegion.self, from: saved)
    check(old.start == nil && old.end == nil, "an area saved before times decodes as covering the whole recording")
    let encoded = String(decoding: try JSONEncoder().encode(BlurRegion(rect: rect)), as: UTF8.self)
    check(!encoded.contains("start") && !encoded.contains("end"), "an untimed area saves no times", encoded)

    print("\nTimed blur areas in the export")
    let detail = scratch.appendingPathComponent("timed-detail.mov")
    _ = try await Shell.run(ffmpeg, [
        "-hide_banner", "-loglevel", "error", "-y",
        "-f", "lavfi", "-i", "color=black:s=640x360:r=30", "-t", "2",
        "-vf", "format=yuv420p,geq=lum='if(mod(floor(X/8)+floor(Y/8),2),235,16)':cb=128:cr=128",
        "-c:v", "libx264", "-crf", "18", "-pix_fmt", "yuv420p", detail.path,
    ])
    let detailInfo = try await FFmpeg.probe(url: detail)
    let sharp = try await regionDetail(detail, rect, at: 0.5)
    var settings = ExportSettings()
    settings.suffix = "-timed"
    let whole = ClipTimeline(segments: [TimelineSegment(start: 0, end: detailInfo.duration)])
    let out = FFmpeg.outputURL(for: detail, settings: settings)
    try await FFmpeg.export(input: detail, output: out, info: detailInfo, crop: detailInfo.fullFrame,
                            regions: BlurBox.boxes([BlurRegion(rect: rect, start: 0.2, end: 0.8)], on: whole),
                            settings: settings) { _ in }
    let inside = try await regionDetail(out, rect, at: 0.5)
    let outside = try await regionDetail(out, rect, at: 1.5)
    check(inside < sharp * 0.1, "the export blurs a timed area inside its range", String(format: "%.1f -> %.1f", sharp, inside))
    check(outside > sharp * 0.7, "and leaves it sharp outside its range", String(format: "%.1f -> %.1f", sharp, outside))

    // Source 1.0–2.0 is kept, so the area at source 1.2–1.6 plays at 0.2–0.6.
    let kept = [TimelineSegment(start: 1.0, end: 2.0)]
    settings.suffix = "-timed-cut"
    let cutOut = FFmpeg.outputURL(for: detail, settings: settings)
    try await FFmpeg.export(input: detail, output: cutOut, info: detailInfo, crop: detailInfo.fullFrame,
                            regions: BlurBox.boxes([BlurRegion(rect: rect, start: 1.2, end: 1.6)], on: ClipTimeline(segments: kept)),
                            segments: kept, settings: settings) { _ in }
    let played = try await regionDetail(cutOut, rect, at: 0.4)
    let later = try await regionDetail(cutOut, rect, at: 0.85)
    check(played < sharp * 0.1, "after a cut the export blurs the area where its footage plays", String(format: "%.1f", played))
    check(later > sharp * 0.7, "and not where other footage plays", String(format: "%.1f", later))

    print("\nTimed blur areas from an agent and the Studio")
    let editor = freshEditor()
    let clip = editor.items[0].id.uuidString
    let duration = editor.items[0].info?.duration ?? 0
    let areaID = UUID()
    func area() -> BlurRegion? { editor.items[0].blurRegions.first { $0.id == areaID } }
    func apply(_ command: [String: Any]) async -> [String: Any] {
        var request = address(editor)
        request["method"] = "apply"; request["requestID"] = UUID().uuidString; request["client"] = "Claude"
        request["commands"] = [command]
        return await agentCall(editor, request)
    }
    let added = await apply(["type": "addBlurArea", "clipID": clip, "areaID": areaID.uuidString,
                             "rect": ["x": 40, "y": 40, "width": 120, "height": 80], "start": 0.5, "end": 1.0])
    check(added["ok"] as? Bool == true && area()?.start == 0.5 && area()?.end == 1.0, "an agent adds a blur area with a time range")
    let state = agentResult(await agentCall(editor, ["method": "state"]))
    let areas = ((state["clips"] as? [[String: Any]])?.first?["blurAreas"] as? [[String: Any]]) ?? []
    let listed = areas.first { $0["id"] as? String == areaID.uuidString }
    check(listed?["start"] as? Double == 0.5 && listed?["end"] as? Double == 1.0, "state shows the range")
    func update(_ fields: [String: Any]) async -> [String: Any] {
        await apply(["type": "updateBlurArea", "clipID": clip, "areaID": areaID.uuidString].merging(fields) { $1 })
    }
    let moved = await update(["start": 0.25])
    check(moved["ok"] as? Bool == true && area()?.start == 0.25 && area()?.end == 1.0 && area()?.rect.width == 120,
          "updateBlurArea changes only the start")
    check(editor.undoTitle.hasPrefix("Undo Blur Time"), "a time change is its own undo step", editor.undoTitle)
    let backwards = await update(["end": 0.1])
    check(backwards["ok"] as? Bool != true && area()?.end == 1.0, "an end before the start is refused")
    let late = await update(["end": duration + 5])
    check(late["ok"] as? Bool != true && area()?.end == 1.0, "a time after the recording's end is refused")
    let nothing = await update([:])
    check(nothing["ok"] as? Bool != true, "an update with nothing to change is refused")
    let wholeAgain = await update(["whole": true])
    check(wholeAgain["ok"] as? Bool == true && area()?.isTimed == false, "whole: true covers the whole recording again")

    // Two points in the first section, where the source time goes up with the playhead.
    editor.selectedRegionID = areaID
    let first = editor.items[0].timeline.segments[0].duration, total = editor.items[0].editedDuration
    editor.setPreviewFraction(first * 0.2 / total)
    let startSource = editor.items[0].timeline.location(at: editor.previewTime)?.source ?? -1
    editor.setRegionTime(areaID, start: true)
    editor.setPreviewFraction(first * 0.8 / total)
    let endSource = editor.items[0].timeline.location(at: editor.previewTime)?.source ?? -1
    editor.setRegionTime(areaID, start: false)
    check(abs((area()?.start ?? -9) - startSource) < 0.0001 && abs((area()?.end ?? -9) - endSource) < 0.0001,
          "Start Here and End Here keep the playhead's source time", "\(area().map { "\($0.start ?? -1)–\($0.end ?? -1)" } ?? "none")")
    editor.coverWholeRecording(areaID)
    check(area()?.isTimed == false, "Whole Recording removes the range")
    try? FileManager.default.removeItem(at: out)
    try? FileManager.default.removeItem(at: cutOut)
}
