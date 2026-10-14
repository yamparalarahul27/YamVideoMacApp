import AppKit
import CoreImage

// MARK: - Colour actions

/// What the Colour inspector does for a person. Every change goes through the same
/// commands agents use, so it can be undone and agents see it.
@MainActor
extension AppModel {
    /// The conversion Natural colour would use for a recording right now: its own table
    /// if this Mac has it, otherwise DJI's official one if it was imported before.
    func availableConversion(for item: VideoItem) -> LUTAssetRef? {
        if let ref = item.color.technicalLUT, LUTStore.has(ref.sha256) { return ref }
        guard LUTStore.has(LUTStore.officialPocket3) else { return nil }
        return LUTAssetRef(sha256: LUTStore.officialPocket3,
                           originalName: "DJI OSMO Pocket 3 D-Log M to Rec.709 V1.cube", role: .pocket3DLogMToRec709)
    }

    private func editColor(_ commands: [EditCommand], label: String? = nil) {
        if case .failure(let error) = perform(commands, label: label) { statusMessage = error.message }
    }

    func setInputProfile(_ profile: ColorInputProfile) {
        guard let item = selectedItem, item.color.inputProfile != profile else { return }
        editColor([.setInputProfile(clip: item.id, profile: profile)])
    }

    /// One undoable step: D-Log M, the conversion, and Natural colour on.
    func applyNaturalColor(_ lut: LUTAssetRef? = nil) {
        guard let item = selectedItem, let lut = lut ?? availableConversion(for: item) else { return }
        var commands: [EditCommand] = []
        if item.color.inputProfile != .pocket3DLogM { commands.append(.setInputProfile(clip: item.id, profile: .pocket3DLogM)) }
        if item.color.technicalLUT != lut { commands.append(.setTechnicalLUT(clip: item.id, lut: lut)) }
        commands.append(.setColorCorrection(clip: item.id, enabled: true))
        if case .failure(let error) = perform(commands, label: "Natural Colour") {
            statusMessage = error.message
        } else {
            statusMessage = LUTStore.isOfficial(lut) ? "Pocket 3 correction applied with DJI's conversion."
                : "Correction applied with \(lut.originalName), which is not DJI's official conversion."
        }
    }

    func removeColorCorrection() {
        guard let item = selectedItem, item.color.correctionEnabled else { return }
        editColor([.setColorCorrection(clip: item.id, enabled: false)])
    }

    /// Picks a `.cube` file, checks it and applies it as Natural colour. A file that is
    /// not a usable table changes nothing and says why.
    func importConversion() {
        let panel = NSOpenPanel()
        panel.title = "Choose DJI's Pocket 3 D-Log M to Rec.709 conversion"
        panel.message = "Choose the .cube file you downloaded from DJI."
        panel.allowedContentTypes = [.init(filenameExtension: "cube") ?? .data]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            applyNaturalColor(try LUTStore.importTable(at: url, role: .pocket3DLogMToRec709))
            // Re-importing a missing table changes no settings, but the picture can now
            // be corrected.
            refreshPreview()
        } catch {
            statusMessage = "\(url.lastPathComponent) cannot be used: \(error.localizedDescription)"
        }
    }

    func openConversionDownload() { NSWorkspace.shared.open(LUTStore.downloadPage) }

    /// A slider. `live` while it is being dragged: shown at once, committed as one step
    /// when the drag ends.
    func setColorAdjustments(_ adjustments: ColorAdjustments, live: Bool = false) {
        guard let item = selectedItem else { return }
        let command = EditCommand.setColorAdjustments(clip: item.id, exposureEV: adjustments.exposureEV, warmth: adjustments.warmth,
                                                      contrast: adjustments.contrast, saturation: adjustments.saturation)
        let key = "colour-\(item.id)"
        if live || isGestureOpen(key) {
            if let error = updateGesture(key, label: "Adjust Colour", [command]) { statusMessage = error.message }
            if live { refreshPreview(); return }
            endGesture(); return
        }
        guard adjustments != item.color.adjustments else { return }
        editColor([command])
    }

    func resetColorAdjustments() {
        guard let item = selectedItem, !item.color.adjustments.isNeutral else { return }
        editColor([.resetColorAdjustments(clip: item.id)])
    }

    func copyColor(to targets: [UUID], includeInterpretation: Bool) {
        guard let item = selectedItem, !targets.isEmpty else { return }
        if case .failure(let error) = perform([.copyColor(from: item.id, to: targets, includeInterpretation: includeInterpretation)]) {
            statusMessage = error.message
        } else {
            statusMessage = "Copied colour to \(targets.count) recording\(targets.count == 1 ? "" : "s")."
        }
    }
}

// MARK: - Fast preview

extension ColorPipeline {
    private static let previewContext = CIContext(options: [.cacheIntermediates: false])

    /// The colour stage applied by Core Image to an uncorrected preview frame: what a
    /// slider shows within a frame or two, while ffmpeg renders the exact one. It is an
    /// approximation only in that blur areas were drawn before the colour, not after.
    static func quickPreview(_ image: NSImage, _ render: ColorRender) -> NSImage? {
        guard let frame = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let space = frame.colorSpace ?? videoSpace
        let input = CIImage(cgImage: frame)
        let output = apply(render, to: input, space: space)
        guard let result = previewContext.createCGImage(output, from: input.extent, format: .RGBA8, colorSpace: space) else { return nil }
        return NSImage(cgImage: result, size: image.size)
    }
}
