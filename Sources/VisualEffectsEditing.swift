import Foundation

/// What the Effects lane, the inspector and the keyboard do with blur effects and
/// markers. Ordinary input is clamped here — a block dragged into its neighbour stops at
/// it — and then goes through the same strict commands agents use.
@MainActor
extension AppModel {
    var selectedEffect: VideoBlurEffect? {
        guard let selectedEffectID else { return nil }
        return selectedItem?.blurEffects.first { $0.id == selectedEffectID }
    }

    var selectedMarker: TimelineMarker? {
        guard let selectedMarkerID else { return nil }
        return selectedItem?.markers.first { $0.id == selectedMarkerID }
    }

    // MARK: Blur effects

    /// A blur from the playhead: three seconds, or up to the next effect or the end,
    /// whichever comes first. Inside an existing effect it starts where that one ends.
    func addBlurEffect() {
        guard let item = selectedItem, let info = item.info else { return }
        let fps = info.fps, frame = 1 / max(1, fps), total = item.editedDuration
        var start = snapToFrame(min(previewTime, total), fps: fps)
        if let containing = item.blurEffects.first(where: { $0.start <= start + 0.000001 && start < $0.end }) { start = containing.end }
        let next = item.blurEffects.filter { $0.start >= start - 0.000001 }.map(\.start).min() ?? total
        let end = (min(start + VideoBlurEffect.defaultDuration, next, total) * max(1, fps)).rounded(.down) / max(1, fps)
        guard end - start >= frame - 0.000001 else {
            statusMessage = "There is no room for a blur effect here. Move the playhead to a stretch without one."
            return
        }
        let room = (end - start) / 2
        let effect = VideoBlurEffect(start: start, end: end, fadeIn: min(VideoBlurEffect.defaultFade, room),
                                     fadeOut: min(VideoBlurEffect.defaultFade, room))
        switch perform([.addBlurEffect(clip: item.id, effect: effect)]) {
        case .success:
            selectedEffectID = effect.id
            statusMessage = String(format: "Blur effect from %@ to %@.", timelineTime(effect.start), timelineTime(effect.end))
        case .failure(let error): statusMessage = error.message
        }
    }

    /// Changes one effect. `live` while a drag or slider is moving: shown at once and
    /// committed as one undo step when it ends.
    func updateEffect(_ id: VideoBlurEffect.ID, live: Bool = false, _ change: (inout VideoBlurEffect) -> Void) {
        guard let item = selectedItem, let info = item.info,
              let original = item.blurEffects.first(where: { $0.id == id }) else { return }
        var effect = original
        change(&effect)
        effect = fitted(effect, replacing: original, in: item, fps: info.fps)
        let command = EditCommand.updateBlurEffect(clip: item.id, effect: effect)
        let key = "effect-\(id)"
        if live || isGestureOpen(key) {
            if let error = updateGesture(key, label: "Adjust Blur Effect", [command], keepPreview: true) { statusMessage = error.message }
            refreshComposedPreview()
            if !live { endGesture() }
            return
        }
        guard effect != original else { return }
        if case .failure(let error) = perform([command]) { statusMessage = error.message }
    }

    /// The UI's version of an edit: snapped to frames, kept inside the recording and
    /// clear of its neighbours, with fades shortened to fit. A move keeps its length;
    /// a trim keeps the edge that was not dragged.
    func fitted(_ effect: VideoBlurEffect, replacing original: VideoBlurEffect, in item: VideoItem, fps: Double) -> VideoBlurEffect {
        let frame = 1 / max(1, fps), total = item.editedDuration
        let others = item.blurEffects.filter { $0.id != original.id }
        let lower = others.filter { $0.end <= original.start + 0.000001 }.map(\.end).max() ?? 0
        let upper = others.filter { $0.start >= original.end - 0.000001 }.map(\.start).min() ?? total
        var result = effect.snapped(fps: fps)
        let moved = abs(effect.duration - original.duration) < 0.000001 && effect.start != original.start
        if moved {
            let length = min(original.duration, upper - lower)
            result.start = min(max(lower, result.start), upper - length)
            result.end = result.start + length
        } else {
            result.start = min(max(lower, result.start), result.end - frame)
            result.end = max(min(upper, result.end), result.start + frame)
        }
        result.amount = min(max(result.amount, VideoBlurEffect.amountRange.lowerBound), VideoBlurEffect.amountRange.upperBound)
        result.mix = min(max(result.mix, 0), 1)
        result.fadeIn = max(0, result.fadeIn); result.fadeOut = max(0, result.fadeOut)
        if result.fadeIn + result.fadeOut > result.duration {
            if effect.fadeIn != original.fadeIn {
                result.fadeIn = max(0, result.duration - result.fadeOut)
            } else if effect.fadeOut != original.fadeOut {
                result.fadeOut = max(0, result.duration - result.fadeIn)
            } else {
                let scale = result.duration / (result.fadeIn + result.fadeOut)
                result.fadeIn *= scale; result.fadeOut *= scale
            }
        }
        return result
    }

    func toggleSelectedEffect() {
        guard let effect = selectedEffect else { return }
        updateEffect(effect.id) { $0.isEnabled.toggle() }
    }

    func removeSelectedEffect() {
        guard let item = selectedItem, let id = selectedEffectID else { return }
        if case .success = perform([.removeBlurEffect(clip: item.id, effect: id)]) { selectedEffectID = nil }
    }

    /// The playhead to a moment that shows the effect at full strength.
    func jumpToEffect(_ effect: VideoBlurEffect) {
        guard let item = selectedItem, item.editedDuration > 0 else { return }
        selectedEffectID = effect.id
        playback.pause()
        let hold = effect.start + effect.fadeIn + max(0, effect.duration - effect.fadeIn - effect.fadeOut) / 2
        setPreviewFraction(min(hold, effect.end - 0.000001) / item.editedDuration)
    }

    /// Effects mode shows the composed picture; this keeps it current while an effect
    /// is being dragged or adjusted.
    func refreshComposedPreview() {
        guard showPlayback, let item = selectedItem, !isMovieMode else { return }
        playback.prepare(item, settings: settings, at: previewTime, play: false, original: colorComparison == .original)
    }

    // MARK: Markers

    /// M: a marker at the playhead, unless one is already on this frame.
    func addMarkerAtPlayhead() {
        guard let item = selectedItem, let info = item.info else { return }
        let time = snapToFrame(previewTime, fps: info.fps)
        if let existing = item.markers.first(where: { abs($0.time - time) < 0.5 / max(1, info.fps) }) {
            selectedMarkerID = existing.id
            statusMessage = "There is already a marker here."
            return
        }
        let marker = TimelineMarker(time: time, label: "", color: .blue)
        if case .success = perform([.addMarker(clip: item.id, marker: marker)]) {
            selectedMarkerID = marker.id
            statusMessage = "Marker at \(timelineTime(time)). Name it in the inspector (⇧M)."
        }
    }

    func updateMarker(_ id: TimelineMarker.ID, _ change: (inout TimelineMarker) -> Void) {
        guard let item = selectedItem, let original = item.markers.first(where: { $0.id == id }) else { return }
        var marker = original
        change(&marker)
        marker.time = min(max(0, marker.time), item.editedDuration)
        marker.label = String(marker.label.filter { !$0.isNewline }.prefix(TimelineMarker.maximumLabel))
        guard marker != original else { return }
        if case .failure(let error) = perform([.updateMarker(clip: item.id, marker: marker)]) { statusMessage = error.message }
    }

    func removeSelectedMarker() {
        guard let item = selectedItem, let id = selectedMarkerID else { return }
        if case .success = perform([.removeMarker(clip: item.id, marker: id)]) { selectedMarkerID = nil }
    }

    func selectMarker(_ marker: TimelineMarker) {
        guard let item = selectedItem, item.editedDuration > 0 else { return }
        selectedMarkerID = marker.id
        playback.pause()
        setPreviewFraction(marker.time / item.editedDuration)
    }

    /// ⇧↑ / ⇧↓: the nearest marker before or after the playhead. Stops at the ends.
    func jumpToMarker(forward: Bool) {
        guard let item = selectedItem, let info = item.info else { return }
        let now = previewTime, frame = 0.5 / max(1, info.fps)
        let target = forward ? item.markers.first { $0.time > now + frame } : item.markers.last { $0.time < now - frame }
        guard let target else {
            statusMessage = item.markers.isEmpty ? "No markers yet. Press M to add one at the playhead."
                : forward ? "No marker after the playhead." : "No marker before the playhead."
            return
        }
        selectMarker(target)
    }
}
