import Foundation

// MARK: - Tracks

/// The rows of the timeline, top to bottom. What draws over the picture sits above the
/// picture and its sound sits below it, as in Filmora. Each row has a header with its
/// name and, where it means something, an eye (hide in the preview) and a lock (no edits
/// from the timeline).
enum TimelineTrack: String, CaseIterable, Identifiable {
    case shorts, graphics, effects, zoom, screenLayout, screenZoom, video, audio, music, captions

    var id: String { rawValue }

    var label: String {
        switch self {
        case .shorts: return "Shorts"
        case .graphics: return "Graphics"
        case .effects: return "Effects"
        case .zoom: return "Zoom"
        case .screenLayout: return "Layout"
        case .screenZoom: return "Screen zoom"
        case .video: return "Video"
        case .audio: return "Audio"
        case .music: return "Music"
        case .captions: return "Captions"
        }
    }

    var symbol: String {
        switch self {
        case .shorts: return "rectangle.portrait"
        case .graphics: return "rectangle.on.rectangle"
        case .effects: return "camera.filters"
        case .zoom: return "plus.magnifyingglass"
        case .screenLayout: return "rectangle.split.2x1"
        case .screenZoom: return "macwindow"
        case .video: return "film"
        case .audio: return "waveform"
        case .music: return "music.note"
        case .captions: return "captions.bubble"
        }
    }

    /// The eye: hiding changes only the preview. The export always has everything.
    var hides: Bool { [.graphics, .effects, .zoom, .screenZoom].contains(self) }
    /// The speaker: muting changes only the preview, as the eye does for a picture row.
    var mutes: Bool { self == .audio || self == .music }
    /// The lock: the timeline stops taking clicks and drags on the row.
    var locks: Bool { self != .audio }

    /// The rows this recording shows: the screen's rows only with a screen recording.
    static func tracks(for item: VideoItem) -> [TimelineTrack] {
        allCases.filter { item.screen != nil || ($0 != .screenLayout && $0 != .screenZoom) }
    }

    /// Nothing on the row yet, so it folds to a thin row with an Add button. The video,
    /// its sound and a screen's base layout are always there.
    func isEmpty(in item: VideoItem) -> Bool {
        switch self {
        case .shorts: return item.shorts.isEmpty
        case .graphics: return item.graphics?.items.isEmpty ?? true
        case .effects: return item.blurEffects.isEmpty && item.blurRegions.isEmpty
        case .zoom: return item.zoomShots.isEmpty
        case .screenZoom: return item.screen?.zooms.isEmpty ?? true
        case .captions: return item.subtitles == nil && (item.transcript?.words.isEmpty ?? true)
        case .music: return item.music?.pieces.isEmpty ?? true
        case .screenLayout, .video, .audio: return false
        }
    }
}

/// What a person hid, locked or muted on the timeline. A view setting, not part of the
/// project: it changes what the preview shows and what the timeline lets you drag, and
/// never the export or an agent's view of the project.
struct TimelineTrackState: Equatable {
    var hidden: Set<TimelineTrack> = []
    var locked: Set<TimelineTrack> = []
    var muted = false
}

extension VideoItem {
    /// The recording as the preview draws it while some rows are hidden.
    func previewing(hiding hidden: Set<TimelineTrack>) -> VideoItem {
        guard !hidden.isEmpty else { return self }
        var copy = self
        if hidden.contains(.zoom) { copy.zoomShots = [] }
        if hidden.contains(.effects) { copy.blurEffects = []; copy.blurRegions = [] }
        if hidden.contains(.screenZoom) { copy.screen?.zooms = [] }
        if hidden.contains(.graphics) { copy.graphics = nil }
        if hidden.contains(.music) { copy.music = nil }
        return copy
    }
}

// MARK: - The timeline's own actions

extension AppModel {
    func toggleTrackHidden(_ track: TimelineTrack) {
        guard track.hides else { return }
        if timelineTracks.hidden.contains(track) { timelineTracks.hidden.remove(track) } else { timelineTracks.hidden.insert(track) }
        statusMessage = timelineTracks.hidden.contains(track)
            ? "\(track.label) hidden in the preview. The export still has it."
            : "\(track.label) shows in the preview again."
    }

    func toggleTrackLocked(_ track: TimelineTrack) {
        guard track.locks else { return }
        if timelineTracks.locked.contains(track) { timelineTracks.locked.remove(track) } else { timelineTracks.locked.insert(track) }
        statusMessage = timelineTracks.locked.contains(track)
            ? "\(track.label) locked: the timeline does not change it."
            : "\(track.label) unlocked."
    }

    func toggleTrackMuted() {
        timelineTracks.muted.toggle()
        statusMessage = timelineTracks.muted ? "Preview sound off. The export still has sound." : "Preview sound on."
    }

    /// The Music row's speaker: the preview leaves the music out; the export keeps it.
    func toggleMusicMuted() {
        if timelineTracks.hidden.contains(.music) { timelineTracks.hidden.remove(.music) } else { timelineTracks.hidden.insert(.music) }
        statusMessage = timelineTracks.hidden.contains(.music) ? "Music off in the preview. The export still has it." : "Music on in the preview."
    }

    /// Gives the player what the rows say, and shows the change at once.
    func applyTrackState() {
        playback.hiddenTracks = timelineTracks.hidden
        playback.player.isMuted = timelineTracks.muted
        if showPlayback, !isMovieMode, let item = selectedItem {
            playback.prepare(item, settings: settings, at: previewTime, play: playback.isPlaying,
                             original: colorComparison == .original)
        }
    }

    /// The row the inspector's selection sits on, if it has one.
    var selectionTrack: TimelineTrack? {
        switch inspectorFocus {
        case .section: return .video
        case .zoom: return .zoom
        case .blurArea, .effect: return .effects
        case .graphic: return .graphics
        case .short: return .shorts
        case .layout: return .screenLayout
        case .screenZoom: return .screenZoom
        case .caption: return .captions
        case .music: return .music
        case .marker, .recording: return nil
        }
    }

    var canDeleteSelection: Bool { inspectorFocus != .recording && !isConverting }

    /// The timeline's Delete: whatever the inspector shows. A section closes its gap, as
    /// the ⌫ key does.
    func deleteSelection() {
        if let track = selectionTrack, timelineTracks.locked.contains(track) {
            statusMessage = "\(track.label) is locked. Unlock it to delete."
            return
        }
        switch inspectorFocus {
        case .section: deleteSegment()
        case .zoom: removeSelectedZoom()
        case .blurArea: removeSelectedRegion()
        case .effect: removeSelectedEffect()
        case .marker: removeSelectedMarker()
        case .graphic: removeSelectedGraphic()
        case .short: removeSelectedShort()
        case .layout: removeSelectedLayout()
        case .screenZoom: removeSelectedScreenZoom()
        case .music: removeSelectedMusic()
        case .caption: statusMessage = "Captions follow what is said. Cut the section to remove a caption, or change its words in the inspector."
        case .recording: statusMessage = "Select something on the timeline to delete it."
        }
    }

    /// The Zoom tool: a zoom at the playhead, aimed at the middle of the frame.
    func addZoomFromTimeline() {
        guard !timelineTracks.locked.contains(.zoom) else { statusMessage = "Zoom is locked. Unlock it to add a zoom."; return }
        addZoomAtCentre()
    }
}

// MARK: - Badges

/// A small mark on a section that says what is applied to it.
enum SectionBadge: Equatable {
    case speed(Double), crop, blur, colour

    var symbol: String {
        switch self {
        case .speed: return "gauge.with.dots.needle.67percent"
        case .crop: return "crop"
        case .blur: return "camera.filters"
        case .colour: return "circle.lefthalf.filled"
        }
    }

    var help: String {
        switch self {
        case .speed(let speed): return "Plays at \(speed.formatted())×"
        case .crop: return "Cropped. The crop applies to the whole recording."
        case .blur: return "Blur areas. They apply to the whole recording."
        case .colour: return "Colour correction. It applies to the whole recording."
        }
    }
}

extension VideoItem {
    /// The badges for one section, in the order the section shows them.
    func badges(for segment: TimelineSegment, settings: ExportSettings) -> [SectionBadge] {
        var badges: [SectionBadge] = []
        if segment.speed != 1 { badges.append(.speed(segment.speed)) }
        if isOn(.crop), !cropIsFullFrame { badges.append(.crop) }
        if isOn(.blurAreas), !blurRegions.isEmpty { badges.append(.blur) }
        if colorStage(settings).render != nil { badges.append(.colour) }
        return badges
    }
}

// MARK: - Filmstrip

/// Where one section's filmstrip puts its frames: a tile every `tileWidth` points, each
/// showing the recording at the tile's middle. Only the tiles on screen are made, and
/// source times are rounded to a step, so a scroll or a small zoom reuses frames.
enum Filmstrip {
    /// Seconds of source between two frames worth making.
    static let steps: [Double] = [0.5, 1, 2, 5, 10, 15, 30, 60, 120]

    /// The finest step at least as long as the source one tile covers.
    static func step(pixelsPerSecond: Double, speed: Double, tileWidth: Double) -> Double {
        let covered = tileWidth / max(0.000001, pixelsPerSecond) * speed
        return steps.first { $0 >= covered } ?? steps[steps.count - 1]
    }

    /// The tiles of a section that starts at `offset` on the timeline: each tile's x from
    /// the section's leading edge, and the source time it shows.
    static func tiles(for segment: TimelineSegment, offset: Double, viewport: TimelineViewport,
                      width: Double, tileWidth: Double) -> [(x: Double, source: Double)] {
        let pixels = viewport.pixels(across: width)
        guard pixels > 0, tileWidth > 0, segment.duration > 0 else { return [] }
        let tileSeconds = tileWidth / pixels
        let count = Int(ceil(segment.duration / tileSeconds))
        let first = max(0, Int(floor((viewport.start - offset) / tileSeconds)))
        let last = min(count - 1, Int(ceil((viewport.end - offset) / tileSeconds)))
        guard first <= last else { return [] }
        let step = Self.step(pixelsPerSecond: pixels, speed: segment.speed, tileWidth: tileWidth)
        return (first...last).map { index in
            let middle = segment.start + (Double(index) + 0.5) * tileSeconds * segment.speed
            let rounded = (middle / step).rounded() * step
            return (Double(index) * tileWidth, min(segment.end, max(segment.start, rounded)))
        }
    }
}
