import AppKit
import Foundation

/// What the Screen section, the Layout lane and the keyboard do with a recording's screen.
/// Ordinary input is clamped here — a span dragged into its neighbour stops at it — and
/// then goes through the same strict commands agents use.
@MainActor
extension AppModel {
    var selectedLayout: LayoutSpan? {
        guard let selectedLayoutID else { return nil }
        return selectedItem?.screen?.spans.first { $0.id == selectedLayoutID }
    }

    // MARK: The screen recording

    /// Add Screen Recording…: the file is probed, then attached with the bubble on the
    /// speaker's face, and the Preview shows the result.
    func chooseScreenRecording() {
        guard let item = selectedItem, item.info != nil else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie]
        panel.allowsMultipleSelection = false
        panel.message = "Choose the screen recording to show with \(item.name)."
        panel.directoryURL = item.url.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        attachScreen(url)
    }

    func attachScreen(_ url: URL) {
        guard let item = selectedItem, item.info != nil else { return }
        guard url.standardizedFileURL.path != item.url.standardizedFileURL.path else {
            statusMessage = "Choose another file: the screen recording cannot be the recording itself."
            return
        }
        statusMessage = "Reading \(url.lastPathComponent)…"
        Task {
            do {
                let info = try await FFmpeg.probe(url: url)
                var screen = item.screen ?? ScreenTrack(url: url, info: info)
                screen.url = url
                screen.info = info
                if let crop = screen.crop, !info.fullFrame.contains(crop) { screen.crop = nil }
                if item.screen == nil {
                    screen.bubble.face = try? await speakerFace(ProjectClip(item), at: item.editedDuration / 2)
                }
                switch perform([.setScreen(clip: item.id, screen: screen)]) {
                case .success:
                    statusMessage = "Added \(url.lastPathComponent). Set the offset so that the screen and the speaker line up."
                    setViewer(.preview)
                case .failure(let error):
                    statusMessage = error.message
                }
            } catch {
                statusMessage = "\(url.lastPathComponent) could not be read as video: \(error.localizedDescription)"
            }
        }
    }

    /// Changes the screen. `live` while a slider moves: shown at once and committed as one
    /// undo step when it ends.
    func updateScreen(live: Bool = false, label: String = "Screen Recording", _ change: (inout ScreenTrack) -> Void) {
        guard let item = selectedItem, let original = item.screen else { return }
        var screen = original
        change(&screen)
        let command = EditCommand.setScreen(clip: item.id, screen: screen)
        let key = "screen-\(item.id)"
        if live || isGestureOpen(key) {
            if let error = updateGesture(key, label: label, [command], keepPreview: true) { statusMessage = error.message }
            refreshComposedPreview()
            if !live { endGesture() }
            return
        }
        guard screen != original else { return }
        if case .failure(let error) = perform([command], label: label) { statusMessage = error.message }
    }

    func removeScreen() {
        guard let item = selectedItem, item.screen != nil else { return }
        if case .success = perform([.setScreen(clip: item.id, screen: nil)]) { selectedLayoutID = nil }
    }

    /// The screen recording's time at the playhead.
    var screenTimeAtPlayhead: Double? {
        guard let item = selectedItem, let screen = item.screen, let source = item.timeline.location(at: previewTime)?.source else { return nil }
        return screen.screenTime(forSource: source)
    }

    /// Lines the two up from one moment: the screen recording's time that belongs at the
    /// playhead. The offset follows.
    func setScreenTime(atPlayhead time: Double) {
        guard let item = selectedItem, let source = item.timeline.location(at: previewTime)?.source else { return }
        updateScreen(label: "Screen Offset") { $0.offset = time - source }
    }

    func nudgeScreenOffset(by seconds: Double) {
        updateScreen(label: "Screen Offset") { $0.offset += seconds }
    }

    /// Crops the dark border round the screen recording, if it has one.
    func cropScreenBorder() {
        guard let screen = selectedItem?.screen else { return }
        statusMessage = "Looking for a border round the screen recording…"
        Task {
            do {
                guard let box = try await FFmpeg.screenBorder(screen.url, info: screen.info) else {
                    statusMessage = "The screen recording has no dark border to crop."
                    return
                }
                updateScreen(label: "Crop Screen") { $0.crop = box }
                statusMessage = "The screen shows \(Int(box.width))×\(Int(box.height)) of the \(screen.info.width)×\(screen.info.height) recording."
            } catch {
                statusMessage = error.localizedDescription
            }
        }
    }

    /// Puts the bubble on the face Apple Vision finds at the playhead.
    func findSpeaker() {
        guard let item = selectedItem, item.screen != nil else { return }
        let time = previewTime
        statusMessage = "Looking for the speaker…"
        Task {
            do {
                guard let face = try await speakerFace(ProjectClip(item), at: time) else {
                    statusMessage = "Apple Vision found nobody at the playhead. Move it to a moment where the speaker faces the camera."
                    return
                }
                updateScreen(label: "Bubble on Speaker") { $0.bubble.face = face }
                statusMessage = "The bubble is on the speaker's face."
            } catch {
                statusMessage = error.localizedDescription
            }
        }
    }

    // MARK: Screen zooms

    var selectedScreenZoom: ZoomShot? {
        guard let selectedScreenZoomID else { return nil }
        return selectedItem?.screen?.zooms.first { $0.id == selectedScreenZoomID }
    }

    static let screenZoomLevels = [1.5, 2.0, 3.0]
    static let defaultScreenZoomLevel = 2.0

    /// A 2× zoom on the screen from the playhead, aimed at the middle of the screen. A click
    /// on the screen in the Preview then aims it.
    func addScreenZoomAtPlayhead() {
        guard let item = selectedItem, let screen = item.screen else { return }
        let picture = screen.picture
        let shot = ZoomShot(start: previewTime, level: Self.defaultScreenZoomLevel, target: CGPoint(x: picture.midX, y: picture.midY))
        guard shot.end <= item.editedDuration + 0.001 else {
            statusMessage = "Not enough video left for a \(formatDuration(shot.duration)) zoom."
            return
        }
        guard !screen.zooms.contains(where: { $0.overlaps(shot) }) else {
            statusMessage = "That overlaps a screen zoom. Move the playhead clear of it."
            return
        }
        switch perform([.addScreenZoom(clip: item.id, zoom: shot)]) {
        case .success:
            selectScreenZoom(shot)
            statusMessage = "Screen zoom \(shot.levelLabel) at \(formatDuration(shot.start)). Click the screen in the Preview to aim it."
        case .failure(let error):
            statusMessage = error.message
        }
    }

    /// Applies an edit only if it keeps the zoom inside the recording and clear of the
    /// others. With a `gesture` key the change shows live and is committed when it ends.
    private func mutateScreenZoom(_ id: ZoomShot.ID, gesture: String? = nil, _ transform: (inout ZoomShot) -> Void) {
        guard let item = selectedItem, let screen = item.screen, let original = screen.zooms.first(where: { $0.id == id }) else { return }
        var shot = original
        transform(&shot)
        shot.start = max(0, min(shot.start, max(0, item.editedDuration - shot.duration)))
        shot.hold = max(0.2, shot.hold)
        guard shot.end <= item.editedDuration + 0.001 else {
            statusMessage = "There is not enough video left for that zoom."
            return
        }
        shot.target.x = min(max(0, shot.target.x), CGFloat(screen.info.width))
        shot.target.y = min(max(0, shot.target.y), CGFloat(screen.info.height))
        guard !screen.zooms.contains(where: { $0.id != id && $0.overlaps(shot) }) else {
            statusMessage = "That would overlap another screen zoom."
            return
        }
        let command = EditCommand.updateScreenZoom(clip: item.id, zoom: shot)
        if let gesture {
            if let error = updateGesture(gesture, label: "Adjust Screen Zoom", [command], keepPreview: true) { statusMessage = error.message }
            refreshComposedPreview()
            return
        }
        guard shot != original else { return }
        if case .failure(let error) = perform([command]) { statusMessage = error.message }
    }

    func setScreenZoomLevel(_ id: ZoomShot.ID, _ level: Double) { mutateScreenZoom(id) { $0.level = level } }

    /// `live` while the hold slider moves; the slider ends the gesture.
    func setScreenZoomHold(_ id: ZoomShot.ID, _ hold: Double, live: Bool = false) {
        let duration = selectedItem?.editedDuration ?? 0
        mutateScreenZoom(id, gesture: live ? "screen-zoom-hold-\(id)" : nil) { shot in
            shot.hold = min(max(0.2, hold), max(0.2, duration - shot.start - 2 * ZoomShot.ease))
        }
    }

    func setScreenZoomStart(_ id: ZoomShot.ID, _ start: Double) { mutateScreenZoom(id) { $0.start = start } }

    func setScreenZoomTarget(_ id: ZoomShot.ID, _ target: CGPoint) { mutateScreenZoom(id) { $0.target = target } }

    func retimeSelectedScreenZoomToPlayhead() {
        guard let id = selectedScreenZoomID else { return }
        setScreenZoomStart(id, previewTime)
    }

    func removeSelectedScreenZoom() {
        guard let item = selectedItem, let id = selectedScreenZoomID else { return }
        if case .success = perform([.removeScreenZoom(clip: item.id, zoom: id)]) { selectedScreenZoomID = nil }
    }

    func clearScreenZooms() {
        guard let item = selectedItem, item.screen?.zooms.isEmpty == false else { return }
        perform([.replaceScreenZooms(clip: item.id, zooms: [])], label: "Clear Screen Zooms")
    }

    /// Selects a screen zoom and shows the middle of its hold in the Preview.
    func selectScreenZoom(_ shot: ZoomShot) {
        guard let item = selectedItem, item.editedDuration > 0 else { return }
        selectedScreenZoomID = shot.id
        playback.pause()
        if !showPlayback { setViewer(.preview) }
        setPreviewFraction(min(shot.start + ZoomShot.ease + shot.hold / 2, item.editedDuration) / item.editedDuration)
    }

    /// A click on the Preview at `point` (pixels of the frame) aims the selected screen
    /// zoom there, through the layout and the zoom on screen at the playhead.
    func aimScreenZoom(at point: CGPoint) {
        guard let item = selectedItem, let info = item.info, let screen = item.screen, let id = selectedScreenZoomID else { return }
        let crop = (item.crop ?? info.fullFrame).evenClamped(in: info.fullFrame)
        let geometry = LayoutGeometry(track: screen, crop: crop)
        guard let target = screen.screenPoint(point, at: previewTime, geometry: geometry, endScreen: item.graphics?.endScreen?.start) else {
            statusMessage = "Click on the screen to aim the screen zoom. At the playhead the screen does not show there."
            return
        }
        setScreenZoomTarget(id, target)
        statusMessage = "The screen zoom aims at \(Int(target.x)), \(Int(target.y)) of the screen recording."
    }

    // MARK: Layouts

    /// A layout from the playhead: five seconds, or up to the next layout or the end,
    /// whichever comes first. Inside a layout it starts where that one ends. It takes the
    /// layout the base is not: Speaker over a screen base, else Screen.
    func addLayoutAtPlayhead() {
        guard let item = selectedItem, let info = item.info, let screen = item.screen else { return }
        let fps = max(1, info.fps), frame = 1 / fps, total = item.editedDuration
        var start = snapToFrame(min(previewTime, total), fps: fps)
        if let containing = screen.spans.first(where: { $0.start <= start + 0.000001 && start < $0.end }) { start = containing.end }
        let next = screen.spans.filter { $0.start >= start - 0.000001 }.map(\.start).min() ?? total
        let end = (min(start + LayoutSpan.defaultDuration, next, total) * fps).rounded(.down) / fps
        guard end - start >= frame - 0.000001 else {
            statusMessage = "There is no room for a layout here. Move the playhead to a stretch without one."
            return
        }
        let span = LayoutSpan(start: start, end: end, layout: screen.layout == .speaker ? .screen : .speaker)
        switch perform([.addLayout(clip: item.id, span: span)]) {
        case .success:
            selectedLayoutID = span.id
            statusMessage = "\(span.layout.label) from \(timelineTime(span.start)) to \(timelineTime(span.end))."
        case .failure(let error):
            statusMessage = error.message
        }
    }

    /// Changes one layout, kept inside the recording and clear of its neighbours.
    func updateLayout(_ id: LayoutSpan.ID, _ change: (inout LayoutSpan) -> Void) {
        guard let item = selectedItem, let info = item.info, let screen = item.screen,
              let original = screen.spans.first(where: { $0.id == id }) else { return }
        var span = original
        change(&span)
        span = fitted(span, replacing: original, among: screen.spans, total: item.editedDuration, fps: info.fps)
        guard span != original else { return }
        if case .failure(let error) = perform([.updateLayout(clip: item.id, span: span)]) { statusMessage = error.message }
    }

    /// Changes one layout's own bubble; a key set to nil follows the screen's bubble
    /// again. `live` while a slider moves: shown at once and committed as one undo step
    /// when it ends.
    func updateLayoutBubble(_ id: LayoutSpan.ID, live: Bool = false, label: String = "Layout Bubble", _ change: (inout SpanBubble) -> Void) {
        guard let item = selectedItem, let original = item.screen?.spans.first(where: { $0.id == id }) else { return }
        var span = original
        var bubble = span.bubble ?? SpanBubble()
        change(&bubble)
        span.bubble = bubble.isEmpty ? nil : bubble
        let command = EditCommand.updateLayout(clip: item.id, span: span)
        let key = "layout-bubble-\(id)"
        if live || isGestureOpen(key) {
            if let error = updateGesture(key, label: label, [command], keepPreview: true) { statusMessage = error.message }
            refreshComposedPreview()
            if !live { endGesture() }
            return
        }
        guard span != original else { return }
        if case .failure(let error) = perform([command], label: label) { statusMessage = error.message }
    }

    /// The UI's version of an edit: snapped to frames, inside the recording and clear of
    /// the neighbours. A move keeps the length; a trim keeps the edge that was not dragged.
    func fitted(_ span: LayoutSpan, replacing original: LayoutSpan, among spans: [LayoutSpan], total: Double, fps: Double) -> LayoutSpan {
        let frame = 1 / max(1, fps)
        let others = spans.filter { $0.id != original.id }
        let lower = others.filter { $0.end <= original.start + 0.000001 }.map(\.end).max() ?? 0
        let upper = others.filter { $0.start >= original.end - 0.000001 }.map(\.start).min() ?? total
        var result = span.snapped(fps: fps)
        let moved = abs(span.duration - original.duration) < 0.000001 && span.start != original.start
        if moved {
            let length = min(original.duration, upper - lower)
            result.start = min(max(lower, result.start), upper - length)
            result.end = result.start + length
        } else {
            result.start = min(max(lower, result.start), result.end - frame)
            result.end = max(min(upper, result.end), result.start + frame)
        }
        return result
    }

    func removeSelectedLayout() {
        guard let item = selectedItem, let id = selectedLayoutID else { return }
        if case .success = perform([.removeLayout(clip: item.id, span: id)]) { selectedLayoutID = nil }
    }

    /// Selects a layout and shows it in the Preview, just after it has eased in.
    func selectLayout(_ span: LayoutSpan) {
        guard let item = selectedItem, item.editedDuration > 0 else { return }
        selectedLayoutID = span.id
        playback.pause()
        let settled = span.start + min(ScreenTrack.transition + 0.1, span.duration / 2)
        setPreviewFraction(min(settled, span.end - 0.000001) / item.editedDuration)
    }
}
