import AppKit
import Foundation

/// Changes you can switch off (step 3 of the Studio redesign): the saved on/off state,
/// what "off" leaves out of the player and exports, the reset, agents, and the inspector
/// tabs.
@MainActor func changesTests() async throws {
    print("\nSwitch a change off")
    let model = freshEditor()
    guard let first = model.selectedItem, let info = first.info else {
        check(false, "the round-trip project has a probed recording"); return
    }
    check(first.switchedOff.isEmpty, "every change starts on")
    let half = CGRect(x: 0, y: 0, width: info.width / 2, height: info.height / 2)
    model.updateCrop(half)
    check(model.selectedItem?.has(.crop) == true, "a crop is a change to switch")
    let steps = model.undoEntries.count
    model.setChange(.crop, on: false)
    check(model.selectedItem?.isOn(.crop) == false, "the switch turns the crop off")
    equal(model.undoEntries.count, steps + 1, "as one undo step")
    equal(model.selectedItem?.crop, half.evenClamped(in: info.fullFrame), "the project keeps the crop")
    check(model.selectedItem?.effective.cropIsFullFrame == true, "but the video plays and exports the whole frame")
    check(model.selectedItem.map { !$0.badges(for: $0.timeline.segments[0], settings: model.settings).contains(.crop) } == true,
          "and the sections lose their crop badge")
    model.undoEdit()
    check(model.selectedItem?.isOn(.crop) == true, "Undo switches it on again")

    var item = first
    item.zoomShots = [ZoomShot(start: 0.2, target: CGPoint(x: 50, y: 50))]
    item.blurRegions = [BlurRegion(rect: CGRect(x: 0, y: 0, width: 32, height: 32))]
    item.switchedOff = [.zooms, .blurAreas]
    let effective = item.effective
    check(effective.zoomShots.isEmpty && effective.blurRegions.isEmpty, "zooms and blur areas off leave the video")
    check(item.zoomShots.count == 1 && item.blurRegions.count == 1, "and come back as they were when switched on")

    model.setColorAdjustments(ColorAdjustments(exposureEV: 0.4, warmth: 0.1, contrast: 1.1, saturation: 1.1))
    check(model.selectedItem?.colorStage(model.settings).render != nil, "adjusted colour has a colour stage")
    model.setChange(.colour, on: false)
    check(model.selectedItem?.colorStage(model.settings).render == nil, "colour off plays and exports the recorded colour")
    check(model.selectedItem?.color.adjustments.isNeutral == false, "and keeps the adjustments")
    model.setChange(.colour, on: true)

    print("\nThe project file")
    var saved = first
    saved.switchedOff = [.zooms, .blurAreas]
    var clip = ProjectClip(saved)
    equal(clip.switchedOff, [.blurAreas, .zooms], "the project saves what is off, in a fixed order")
    let project = VideoProject(clips: [clip], settings: ExportSettings(), selection: clip.id)
    let data = try JSONEncoder().encode(project)
    let read = try VideoProject.decodeMigrating(from: data)
    equal(read.version, VideoProject.currentVersion, "a project is saved as the current version")
    equal(read.clips.first?.item().switchedOff, [.zooms, .blurAreas], "and reads back with the same changes off")
    var older = project
    older.version = 17
    check((try? older.validate()) == nil, "a version 17 file with changes off is refused")
    clip.switchedOff = nil
    var plain = project
    plain.version = 17; plain.clips = [clip]
    check((try? plain.validate()) != nil, "a version 17 file with every change on still opens")

    print("\nReset")
    let resetModel = freshEditor()
    resetModel.updateCrop(half)
    resetModel.setChange(.crop, on: false)
    resetModel.resetChange(.crop)
    check(resetModel.selectedItem?.cropIsFullFrame == true && resetModel.selectedItem?.isOn(.crop) == true,
          "reset puts the crop back to the whole frame and switches it on")

    print("\nCaptions and loudness")
    let audio = freshEditor()
    audio.setLoudness(on: true)
    check(audio.loudnessOn && audio.settings.audio == .normalised, "loudness on normalises the export")
    audio.setLoudness(on: false)
    check(!audio.loudnessOn && audio.settings.audio == .aac, "and off keeps the level as recorded")

    print("\nAgents")
    let agent = freshEditor()
    let agentClip = agent.items[0].id.uuidString
    var off = address(agent)
    off["method"] = "apply"; off["requestID"] = "switch-1"; off["client"] = "Claude"
    off["commands"] = [["type": "setChange", "clipID": agentClip, "change": "zooms", "on": false]]
    let applied = await agentCall(agent, off)
    check(applied["ok"] as? Bool == true && agent.items[0].isOn(.zooms) == false, "an agent switches a change off")
    let state = agentResult(await agentCall(agent, ["method": "state"]))
    let clips = state["clips"] as? [[String: Any]] ?? []
    equal(clips.first?["switchedOff"] as? [String], ["zooms"], "and state lists what is off")
    var unknown = address(agent)
    unknown["method"] = "apply"; unknown["requestID"] = "switch-2"
    unknown["commands"] = [["type": "setChange", "clipID": agentClip, "change": "volume", "on": false]]
    check(agentError(await agentCall(agent, unknown)) != nil, "an unknown change is refused")

    print("\nExports leave out what is off")
    var crop = address(agent)
    crop["method"] = "apply"; crop["requestID"] = "switch-3"
    crop["commands"] = [["type": "setCrop", "clipID": agentClip, "rect": ["x": 0, "y": 0, "width": info.width / 2, "height": info.height / 2]],
                        ["type": "setChange", "clipID": agentClip, "change": "crop", "on": false]]
    _ = await agentCall(agent, crop)
    let whole = scratch.appendingPathComponent("switch-off.mp4")
    var exporting = address(agent)
    exporting["method"] = "export"; exporting["requestID"] = "switch-export-1"; exporting["clip"] = agentClip; exporting["path"] = whole.path
    let job = agentResult(await agentCall(agent, exporting))
    _ = try await waitForJob(agent, job["id"] as? String ?? "")
    let wholeInfo = try await FFmpeg.probe(url: whole)
    equal(wholeInfo.width, info.width, "with the crop off, the export has the whole frame")
    var on = address(agent)
    on["method"] = "apply"; on["requestID"] = "switch-4"
    on["commands"] = [["type": "setChange", "clipID": agentClip, "change": "crop", "on": true]]
    _ = await agentCall(agent, on)
    let cropped = scratch.appendingPathComponent("switch-on.mp4")
    var again = address(agent)
    again["method"] = "export"; again["requestID"] = "switch-export-2"; again["clip"] = agentClip; again["path"] = cropped.path
    let againJob = agentResult(await agentCall(agent, again))
    _ = try await waitForJob(agent, againJob["id"] as? String ?? "")
    let croppedInfo = try await FFmpeg.probe(url: cropped)
    equal(croppedInfo.width, info.width / 2, "and with it on again, the export is cropped")

    print("\nInspector tabs")
    let tabs = freshEditor()
    tabs.inspectorFocus = .recording
    equal(tabs.inspectorTabs, [.video, .audio, .colour], "with nothing selected: Video, Audio and Colour")
    equal(tabs.shownInspectorTab, .video, "and Video shows")
    if let section = tabs.selectedItem?.timeline.segments.first {
        tabs.selectSegment(section.id)
        equal(tabs.inspectorTabs, [.speed, .video, .audio, .colour], "a section adds Speed")
        equal(tabs.shownInspectorTab, .speed, "and shows it first")
        tabs.inspectorTab = .colour
        tabs.selectSegment(section.id)
        equal(tabs.shownInspectorTab, .colour, "a tab you pick stays")
    }
    tabs.inspectorFocus = .recording
    tabs.inspectorTab = .speed
    equal(tabs.shownInspectorTab, .video, "Speed with no section falls back to Video")
    tabs.setPreviewFraction(0.1)
    tabs.showSpeedTab()
    check(tabs.inspectorFocus == .section && tabs.shownInspectorTab == .speed, "⌥R opens Speed for the section under the playhead")
}
