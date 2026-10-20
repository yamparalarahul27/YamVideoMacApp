import AppKit
import AVFoundation
import UniformTypeIdentifiers

// MARK: - The picture's edit states

/// A short edit on the recording's frame. While one is open, the picture area shows the
/// frame with its handles and a bar under it to finish the edit; otherwise the one player
/// plays the edit. Filmora opens a window for its crop; here it stays in place, so the
/// timeline and the inspector stay in view.
enum PictureEdit: Equatable {
    case crop, blurAreas, zoomAim, colourCompare

    /// The handles the frame shows.
    var mode: EditorMode {
        switch self {
        case .crop: return .crop
        case .blurAreas: return .blur
        case .zoomAim: return .zoom
        case .colourCompare: return .effects
        }
    }
}

/// The crop being set in the player, until Apply. Not part of the project.
struct CropDraft: Equatable {
    var rect: CGRect
    /// An `AspectPreset` label: "Free", "16:9" and so on.
    var preset: String

    /// The ratio the corners keep while dragged, or nil for a free crop.
    var ratio: CGFloat? { AspectPreset.all.first { $0.label == preset }?.ratio }
    /// What the export will be, in pixels.
    var size: String { "\(Int(rect.width))×\(Int(rect.height))" }
}

extension VideoItem {
    /// The recording as it was, for Before/After: the same cuts, and no crop, zooms, blur,
    /// graphics, screen recording or music. The player adds no colour stage either.
    var asRecorded: VideoItem {
        var copy = self
        if let info { copy.crop = info.fullFrame }
        copy.aspectLock = nil
        copy.zoomShots = []
        copy.blurRegions = []
        copy.blurEffects = []
        copy.graphics = nil
        copy.screen = nil
        copy.music = nil
        return copy
    }
}

extension AppModel {
    /// Opens an edit on the frame: playback stops and the frame shows its handles.
    func beginPictureEdit(_ edit: PictureEdit) {
        guard !isMovieMode, selectedItem?.info != nil else { return }
        playback.pause()
        if showsBefore { setBefore(false) }
        if showsShort { showsShort = false; playback.shortID = nil }
        pictureEdit = edit
        colorComparison = edit == .colourCompare ? .split : .corrected
        setPlaybackVisible(false)
    }

    /// Closes the edit on the frame, and the player plays the edit again.
    func endPictureEdit() {
        guard pictureEdit != nil else { return }
        pictureEdit = nil
        cropDraft = nil
        if colorComparison != .corrected { colorComparison = .corrected }
        setPlaybackVisible(true)
    }

    /// Forgets any open edit, for a new project or another recording.
    func resetPictureEdit() {
        pictureEdit = nil
        cropDraft = nil
        showsBefore = false
        playback.showsOriginal = false
    }

    // MARK: Crop in the player

    /// The Crop tool (⌥C): the whole frame with the crop box on it, and Apply or Cancel.
    func beginCrop() {
        guard let item = selectedItem, let info = item.info else { return }
        cropDraft = CropDraft(rect: item.crop ?? info.fullFrame, preset: item.aspectLabel)
        beginPictureEdit(.crop)
    }

    /// A drag of the crop box or a corner. Nothing changes in the project until Apply.
    func updateCropDraft(_ rect: CGRect) {
        guard let info = selectedItem?.info, var draft = cropDraft, !rect.isNull else { return }
        draft.rect = rect.evenClamped(in: info.fullFrame)
        cropDraft = draft
    }

    /// A ratio chip: the largest crop of that ratio in the frame, as the inspector's
    /// presets make. Free keeps the box and lets the corners move freely.
    func setCropDraftAspect(_ preset: AspectPreset) {
        guard let info = selectedItem?.info, var draft = cropDraft else { return }
        draft.preset = preset.label
        if let ratio = preset.ratio {
            draft.rect = CGRect.centered(aspect: ratio, in: info.fullFrame).evenClamped(in: info.fullFrame)
        }
        cropDraft = draft
    }

    func resetCropDraft() {
        guard let info = selectedItem?.info else { return }
        cropDraft = CropDraft(rect: info.fullFrame, preset: "Free")
    }

    /// Apply: the crop and its ratio as one undo step, then the player again.
    func applyCropDraft() {
        guard let item = selectedItem, let info = item.info, let draft = cropDraft else { endPictureEdit(); return }
        let rect = draft.rect.evenClamped(in: info.fullFrame)
        var commands: [EditCommand] = []
        if draft.preset != item.aspectLabel { commands.append(.setAspect(clip: item.id, preset: draft.preset)) }
        if rect != (item.crop ?? info.fullFrame) { commands.append(.setCrop(clip: item.id, rect: rect)) }
        cropDraft = nil
        if !commands.isEmpty {
            if case .failure(let error) = perform(commands, label: "Crop") { statusMessage = error.message }
            else { statusMessage = "Cropped to \(draft.preset == "Free" ? "" : draft.preset + " · ")\(Int(rect.width))×\(Int(rect.height))." }
        }
        endPictureEdit()
    }

    func cancelCropDraft() {
        cropDraft = nil
        statusMessage = "The crop did not change."
        endPictureEdit()
    }

    // MARK: Blur areas and zoom aim on the frame

    /// Blur areas hide their part of the picture for the whole video, so they are drawn on
    /// the recording's own frame.
    func beginBlurAreas(selecting id: BlurRegion.ID? = nil) {
        beginPictureEdit(.blurAreas)
        selectedRegionID = id ?? selectedItem?.blurRegions.first?.id
    }

    /// Aims the selected zoom: the frame shows what stays in view at the zoom's peak.
    func beginZoomAim() {
        guard let shot = selectedShot else { statusMessage = "Select a zoom on the timeline to aim it."; return }
        beginPictureEdit(.zoomAim)
        selectedShotID = shot.id
    }

    // MARK: The player bar

    func setBefore(_ before: Bool) {
        guard showsBefore != before else { return }
        showsBefore = before
        playback.showsOriginal = before
        if showPlayback, let item = selectedItem, !isMovieMode {
            playback.prepare(item, settings: settings, at: previewTime, play: playback.isPlaying)
        }
        statusMessage = before ? "Before: the recording as it was, with the same cuts. Press Before/After again for the edit." : nil
    }

    /// 9:16 shows the selected Short, or the Short under the playhead, or the first one.
    func setPictureTall(_ tall: Bool) {
        if !tall { setViewer(.preview); return }
        guard let item = selectedItem else { return }
        guard let short = item.short(selectedShortID)
                ?? item.shorts.first(where: { previewTime >= $0.start && previewTime < $0.end })
                ?? item.shorts.first else {
            statusMessage = "Add a Short first: the + on the Shorts row adds one at the playhead."
            return
        }
        if showsBefore { setBefore(false) }
        showShort(short)
    }

    /// Snapshot: the frame under the playhead as the edit shows it, saved as a PNG.
    func saveSnapshot() {
        guard let item = selectedItem, showPlayback, playback.player.currentItem != nil else { return }
        playback.pause()
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.directoryURL = item.url.deletingLastPathComponent()
        let stamp = timelineTime(previewTime).replacingOccurrences(of: ":", with: "-")
        panel.nameFieldStringValue = "\(item.url.deletingPathExtension().lastPathComponent) \(stamp).png"
        panel.message = "The frame as the edit shows it, without graphics."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                let image = try await playback.composedFrame()
                guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
                    statusMessage = "Could not write \(url.lastPathComponent)."; return
                }
                CGImageDestinationAddImage(destination, image, nil)
                statusMessage = CGImageDestinationFinalize(destination)
                    ? "Saved \(url.lastPathComponent), \(image.width)×\(image.height)." : "Could not write \(url.lastPathComponent)."
            } catch {
                statusMessage = "Could not take the snapshot: \(error.localizedDescription)"
            }
        }
    }
}

extension PlaybackController {
    /// The frame under the playhead at full size, made by the same picture the player
    /// shows: crop, zooms, blur and colour. Graphics draw in their own layer, so they are
    /// not in it.
    func composedFrame() async throws -> CGImage {
        guard let item = player.currentItem else { throw CocoaError(.fileNoSuchFile) }
        let generator = AVAssetImageGenerator(asset: item.asset)
        generator.videoComposition = item.videoComposition
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let time = player.currentTime()
        return try await withCheckedThrowingContinuation { continuation in
            generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: time)]) { _, image, _, result, error in
                if let image, result == .succeeded { continuation.resume(returning: image) }
                else { continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown)) }
            }
        }
    }
}
