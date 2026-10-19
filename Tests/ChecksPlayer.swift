import AppKit
import Foundation

/// One player (step 2 of the Studio redesign): the picture's edit states, crop in the
/// player with Apply and Cancel, Before/After, and the player staying up through edits.
@MainActor func playerTests() async throws {
    print("\nOne player")
    let model = freshEditor()
    guard let first = model.selectedItem, let info = first.info else {
        check(false, "the round-trip project has a probed recording"); return
    }
    model.setPlaybackVisible(true)
    check(model.showPlayback && model.pictureEdit == nil, "the player plays the edit, with no edit open on the frame")
    model.setPreviewFraction(0.5)
    model.splitAtPlayhead()
    check(model.showPlayback, "an edit keeps the player up instead of going back to a still frame")
    model.undoEdit()

    print("\nCrop in the player")
    let before = model.selectedItem?.crop
    let steps = model.undoEntries.count
    model.beginCrop()
    equal(model.pictureEdit, .crop, "the Crop tool opens the crop on the frame")
    check(!model.showPlayback, "and the frame takes the player's place")
    equal(model.cropDraft?.rect, before ?? info.fullFrame, "the box starts at the recording's crop")
    if let square = AspectPreset.all.first(where: { $0.label == "1:1" }) { model.setCropDraftAspect(square) }
    equal(model.cropDraft?.preset, "1:1", "a ratio chip sets the box's ratio")
    check(model.cropDraft.map { abs($0.rect.width - $0.rect.height) <= 2 } == true, "and the box is square")
    equal(model.selectedItem?.crop, before, "nothing changes in the project before Apply")
    model.cancelCropDraft()
    check(model.pictureEdit == nil && model.cropDraft == nil && model.showPlayback, "Cancel closes the crop and the player comes back")
    equal(model.selectedItem?.crop, before, "and leaves the crop as it was")
    equal(model.undoEntries.count, steps, "with no undo step")

    model.beginCrop()
    if let square = AspectPreset.all.first(where: { $0.label == "1:1" }) { model.setCropDraftAspect(square) }
    let wanted = model.cropDraft?.rect
    model.applyCropDraft()
    equal(model.selectedItem?.crop, wanted, "Apply sets the crop")
    equal(model.selectedItem?.aspectLabel, "1:1", "and its ratio")
    equal(model.undoEntries.count, steps + 1, "as one undo step")
    check(model.pictureEdit == nil && model.showPlayback, "and the player comes back")
    model.undoEdit()
    equal(model.selectedItem?.crop, before, "Undo restores the crop and its ratio together")
    model.beginCrop()
    model.updateCropDraft(CGRect(x: 1, y: 1, width: 101, height: 77))
    check(model.cropDraft.map { Int($0.rect.minX) % 2 == 0 && Int($0.rect.width) % 2 == 0 } == true,
          "a dragged box keeps the even pixels ffmpeg needs")
    model.resetCropDraft()
    equal(model.cropDraft?.rect, info.fullFrame, "Reset makes the whole frame")
    model.cancelCropDraft()

    print("\nEdits on the frame")
    model.beginBlurAreas()
    equal(model.pictureEdit, .blurAreas, "blur areas open on the frame")
    equal(PictureEdit.blurAreas.mode, .blur, "with the blur handles")
    model.endPictureEdit()
    model.selectedShotID = nil
    model.beginZoomAim()
    check(model.pictureEdit == nil, "aiming needs a selected zoom")
    // The project's own zoom, or a new one where there is room.
    var added = false
    if let zoom = model.selectedItem?.zoomShots.first {
        model.selectedShotID = zoom.id
    } else {
        model.setPreviewFraction(0)
        added = model.addZoom(at: CGPoint(x: info.width / 2, y: info.height / 2))
    }
    check(model.selectedShot != nil, "a zoom to aim", model.statusMessage ?? "")
    model.beginZoomAim()
    equal(model.pictureEdit, .zoomAim, "a selected zoom is aimed on the frame")
    model.endPictureEdit()
    if added { model.undoEdit() }
    model.beginPictureEdit(.colourCompare)
    equal(model.colorComparison, .split, "the colour comparison shows both halves on the frame")
    model.endPictureEdit()
    equal(model.colorComparison, .corrected, "and Done shows the corrected picture again")

    print("\nBefore/After")
    var edited = first
    edited.zoomShots = [ZoomShot(start: 0.2, target: CGPoint(x: 50, y: 50))]
    edited.blurRegions = [BlurRegion(rect: CGRect(x: 0, y: 0, width: 32, height: 32))]
    edited.crop = CGRect(x: 0, y: 0, width: CGFloat(info.width / 2), height: CGFloat(info.height / 2))
    let recorded = edited.asRecorded
    check(recorded.zoomShots.isEmpty && recorded.blurRegions.isEmpty && recorded.cropIsFullFrame,
          "Before is the recording with no crop, zooms or blur")
    equal(recorded.timeline, edited.timeline, "and the same cuts")
    model.setBefore(true)
    check(model.showsBefore && model.playback.showsOriginal, "Before/After tells the player to show the recording as it was")
    model.beginCrop()
    check(!model.showsBefore, "an edit on the frame ends Before")
    model.cancelCropDraft()

    print("\nVideo or Short")
    let noShorts = AppModel(recoveryURL: nil)
    var clip = ProjectClip(VideoItem(url: landscape))
    clip.info = info; clip.crop = info.fullFrame
    noShorts.restore(VideoProject(clips: [clip], settings: ExportSettings(), selection: clip.id))
    noShorts.setPictureTall(true)
    check(!noShorts.showsShort && noShorts.statusMessage?.contains("Add a Short") == true, "Short with no Short says how to add one")
    noShorts.addShortAtPlayhead()
    noShorts.setPictureTall(true)
    check(noShorts.showsShort && noShorts.showPlayback, "with a Short, Short plays it at 9:16")
    noShorts.setPictureTall(false)
    check(!noShorts.showsShort && noShorts.showPlayback, "and Video goes back to the edit")
}
