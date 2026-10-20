import CoreGraphics
import Foundation

// MARK: - Changes a recording can switch off

/// A change to a recording that can be switched off without losing it, as each module in
/// Filmora's property panel can. Off leaves it out of the player and every export; on
/// brings it back exactly as it was. The project saves which are off (version 18).
enum SwitchableChange: String, CaseIterable, Codable, Identifiable, Comparable {
    case crop, colour, blurAreas, zooms, graphics, music

    var id: String { rawValue }

    var label: String {
        switch self {
        case .crop: return "Crop"
        case .colour: return "Colour"
        case .blurAreas: return "Blur areas"
        case .zooms: return "Zooms"
        case .graphics: return "Graphics"
        case .music: return "Music"
        }
    }

    var symbol: String {
        switch self {
        case .crop: return "crop"
        case .colour: return "circle.lefthalf.filled"
        case .blurAreas: return "camera.filters"
        case .zooms: return "plus.magnifyingglass"
        case .graphics: return "rectangle.on.rectangle"
        case .music: return "music.note"
        }
    }

    static func < (a: SwitchableChange, b: SwitchableChange) -> Bool {
        allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)!
    }
}

extension VideoItem {
    func isOn(_ change: SwitchableChange) -> Bool { !switchedOff.contains(change) }

    /// Whether the recording has something of this kind to switch.
    func has(_ change: SwitchableChange) -> Bool {
        switch change {
        case .crop: return !cropIsFullFrame
        case .colour: return !color.isDefault
        case .blurAreas: return !blurRegions.isEmpty
        case .zooms: return !zoomShots.isEmpty
        case .graphics: return !(graphics?.items.isEmpty ?? true)
        case .music: return !(music?.pieces.isEmpty ?? true)
        }
    }

    /// The recording as it plays and exports: switched-off changes left out. The colour
    /// stage reads `switchedOff` itself, so the copy keeps it.
    var effective: VideoItem {
        guard !switchedOff.isEmpty else { return self }
        var copy = self
        if !isOn(.crop), let info { copy.crop = info.fullFrame }
        if !isOn(.blurAreas) { copy.blurRegions = [] }
        if !isOn(.zooms) { copy.zoomShots = [] }
        if !isOn(.graphics) { copy.graphics = nil }
        if !isOn(.music) { copy.music = nil }
        return copy
    }
}

extension ProjectClip {
    func isOn(_ change: SwitchableChange) -> Bool { !(switchedOff ?? []).contains(change) }
}

// MARK: - Inspector tabs

/// The inspector's tabs, as in Filmora's property panel. Speed shows only with a section
/// selected.
enum InspectorTab: String, CaseIterable, Identifiable {
    case speed, video, audio, colour
    var id: String { rawValue }
    var label: String {
        switch self {
        case .speed: return "Speed"
        case .video: return "Video"
        case .audio: return "Audio"
        case .colour: return "Colour"
        }
    }
}

extension AppModel {
    /// The tabs the inspector shows for what is selected.
    var inspectorTabs: [InspectorTab] {
        inspectorFocus == .section ? InspectorTab.allCases : [.video, .audio, .colour]
    }

    /// The tab showing: the one picked last, while it is there; otherwise Speed for a
    /// section and Video for the rest.
    var shownInspectorTab: InspectorTab {
        if let inspectorTab, inspectorTabs.contains(inspectorTab) { return inspectorTab }
        return inspectorFocus == .section ? .speed : .video
    }

    /// ⌥R, Filmora's key for speed: the Speed tab for the section under the playhead.
    func showSpeedTab() {
        if inspectorFocus != .section, let item = selectedItem, let location = item.timeline.location(at: previewTime) {
            selectedSegmentID = item.timeline.segments[location.index].id
        }
        inspectorTab = .speed
    }
}

// MARK: - Switching and resetting

extension AppModel {
    /// The inspector's switch. One undo step, like any edit, and agents see it.
    func setChange(_ change: SwitchableChange, on: Bool) {
        guard let item = selectedItem, item.isOn(change) != on else { return }
        if case .failure(let error) = perform([.setChange(clip: item.id, change: change, on: on)]) {
            statusMessage = error.message
        } else {
            statusMessage = on ? "\(change.label) on." : "\(change.label) off. It stays in the project; switch it on to bring it back."
        }
    }

    /// The inspector's reset: back to no change of this kind, as one undo step.
    func resetChange(_ change: SwitchableChange) {
        guard let item = selectedItem else { return }
        switch change {
        case .crop: resetCrop()
        case .colour: removeColorCorrection()
        case .blurAreas: clearRegions()
        case .zooms: clearZooms()
        case .graphics: statusMessage = "Delete graphics one at a time on the timeline, so none goes by mistake."
        case .music: statusMessage = "Remove music one piece at a time on the timeline, so none goes by mistake."
        }
        // A reset change is on again, so the next one shows at once.
        if change != .graphics, change != .music, !item.isOn(change), selectedItem?.has(change) == false {
            _ = perform([.setChange(clip: item.id, change: change, on: true)], label: "Reset \(change.label)")
        }
    }

    /// Captions as an export setting: on uploads an SRT beside the video, off has none.
    var captionsOn: Bool {
        guard let item = selectedItem else { return false }
        return settings.captionUse(hasFile: item.subtitles != nil) != .off
    }

    func setCaptions(on: Bool) {
        var changed = settings
        changed.captions = on ? .upload : .off
        updateSettings(changed)
        refreshPreview()
    }

    /// Loudness as an export setting: on normalises to -14 LUFS for YouTube.
    var loudnessOn: Bool { settings.audio == .normalised }

    func setLoudness(on: Bool) {
        var changed = settings
        changed.audio = on ? .normalised : .aac
        updateSettings(changed)
    }
}
