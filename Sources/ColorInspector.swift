import SwiftUI

// MARK: - Inspector

/// The Colour section: what the recording is, how to correct it, four plain controls.
/// No wheels, curves or scopes; exact values sit behind Details.
struct ColorInspector: View {
    @EnvironmentObject var model: AppModel
    let item: VideoItem
    let info: MediaInfo
    @State private var copying = false

    private var color: ClipColorSettings { item.color }
    private var inferred: (profile: ColorInputProfile?, evidence: String) { info.inferredColorProfile(fileName: item.name) }
    private var profileInEffect: ColorInputProfile? { color.inputProfile == .auto ? inferred.profile : color.inputProfile }
    private var stage: ColorStage { item.colorStage(model.settings) }

    private var settingsBinding: Binding<ExportSettings> {
        Binding(get: { model.settings }, set: { model.updateSettings($0) })
    }

    var body: some View {
        InspectorSection("Colour", isOn: changeSwitch(.colour, item, model),
                         onReset: item.color.isDefault ? nil : { model.removeColorCorrection() },
                         resetHelp: "Back to the recording's own colour") {
            Picker("Recorded colour", selection: Binding(get: { color.inputProfile }, set: { model.setInputProfile($0) })) {
                Text(autoLabel).tag(ColorInputProfile.auto)
                Text(ColorInputProfile.standard.label).tag(ColorInputProfile.standard)
                if !info.isHDR { Text(ColorInputProfile.pocket3DLogM.label).tag(ColorInputProfile.pocket3DLogM) }
                if info.colorTransfer == "arib-std-b67" { Text(ColorInputProfile.hlg.label).tag(ColorInputProfile.hlg) }
                if info.colorTransfer == "smpte2084" { Text(ColorInputProfile.pq.label).tag(ColorInputProfile.pq) }
            }
            .accessibilityLabel("Recorded colour")
            if color.inputProfile == .auto, inferred.profile == nil {
                note("Choose the colour mode used on your camera. \(inferred.evidence) The picture stays as recorded until you do.",
                     icon: "questionmark.circle.fill", tint: .accentColor)
            }
            if profileInEffect == .pocket3DLogM { dLogM }
            if info.isHDR { hdr }
            if let problem = stage.problem { note(problem, icon: "exclamationmark.triangle.fill", tint: .orange) }

            adjustments

            HStack {
                Button("Reset Adjustments") { model.resetColorAdjustments() }
                    .disabled(color.adjustments.isNeutral)
                    .help("Brightness, warmth, contrast and colour strength back to neutral. Natural colour stays.")
                Spacer()
                Button("Copy Colour…") { copying = true }
                    .disabled(model.items.filter { $0.id != item.id && $0.info != nil }.isEmpty)
            }
            .controlSize(.small)
            if stage.render != nil {
                Button { model.beginPictureEdit(.colourCompare) } label: { Label("Compare on the Frame", systemImage: "circle.lefthalf.filled") }
                    .controlSize(.small)
                    .disabled(model.pictureEdit == .colourCompare || model.isMovieMode)
                    .help("Original on the left and corrected on the right, on the frame under the playhead")
            }
        }
        .sheet(isPresented: $copying) { CopyColorSheet(source: item).environmentObject(model) }
    }

    private var autoLabel: String {
        switch inferred.profile {
        case .some(let profile): return "Auto (\(profile == .standard ? "standard" : profile.label))"
        case .none: return "Auto (not sure)"
        }
    }

    /// Pocket 3 D-Log M: get the conversion once, then Natural colour is one click.
    @ViewBuilder
    private var dLogM: some View {
        Text("D-Log M footage looks flat before correction. Natural colour converts it for standard screens; then you can adjust the look.")
            .font(.caption2).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        if color.correctionEnabled, let lut = color.technicalLUT, LUTStore.has(lut.sha256) {
            Label("Pocket 3 correction applied", systemImage: "checkmark.circle.fill")
                .font(.callout).foregroundStyle(.green)
            Text(LUTStore.isOfficial(lut) ? "Using DJI's official conversion." : "Using \(lut.originalName), not DJI's official conversion.")
                .font(.caption2).foregroundStyle(.secondary)
            Button("Remove Correction") { model.removeColorCorrection() }
                .controlSize(.small)
                .help("Turn the conversion off and see the recording as it was recorded. Your adjustments are kept.")
        } else if let lut = model.availableConversion(for: item) {
            Button { model.applyNaturalColor(lut) } label: { Label("Natural Colour", systemImage: "wand.and.stars") }
                .buttonStyle(.borderedProminent)
                .help(LUTStore.isOfficial(lut) ? "Convert with DJI's official Pocket 3 conversion." : "Convert with \(lut.originalName).")
        } else {
            Text("Natural colour needs DJI's free conversion file. Download it once, then import it here.")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Get DJI Conversion") { model.openConversionDownload() }
                    .help("Opens DJI's download page for the Pocket 3 D-Log M to Rec.709 .cube file.")
                Button("Import Conversion File…") { model.importConversion() }
            }
            .controlSize(.small)
        }
    }

    @ViewBuilder
    private var hdr: some View {
        Toggle("Convert HDR to SDR", isOn: settingsBinding.toneMapHDR)
            .onChange(of: model.settings.toneMapHDR) { _, _ in model.refreshPreview() }
        Text(model.settings.toneMapHDR
             ? "This recording is \(info.hdrLabel ?? "HDR"). It is tone-mapped to Rec.709 so it looks right in browsers and on the web, not just in QuickTime."
             : "Off: the export keeps the HDR transfer. QuickTime will look fine; most other players will show it blown out.")
            .font(.caption2).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        if model.settings.toneMapHDR, !model.toneMappingAvailable {
            note("This ffmpeg has no zscale filter and cannot tone-map. Run brew install ffmpeg-full and relaunch, or turn this off.",
                 icon: "exclamationmark.triangle.fill", tint: .orange)
        }
    }

    private var adjustments: some View {
        VStack(alignment: .leading, spacing: 6) {
            control("Brightness", value: \.exposureEV, range: ColorAdjustments.exposureRange, neutral: 0)
            control("Warmth", value: \.warmth, range: ColorAdjustments.warmthRange, neutral: 0)
            control("Contrast", value: \.contrast, range: ColorAdjustments.contrastRange, neutral: 1)
            control("Colour strength", value: \.saturation, range: ColorAdjustments.saturationRange, neutral: 1)
            DisclosureGroup("Details") {
                VStack(alignment: .leading, spacing: 3) {
                    Text(String(format: "Brightness %+.2f stops", color.exposureEV))
                    Text(String(format: "Warmth %+.2f", color.warmth))
                    Text(String(format: "Contrast %.2f× about 18%% grey", color.contrast))
                    Text(String(format: "Colour strength %.2f×", color.saturation))
                    Text("Adjusted in linear light after any conversion (algorithm \(color.algorithmVersion)).")
                        .foregroundStyle(.tertiary)
                }
                .font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary)
                .padding(.top, 3)
            }
            .font(.caption)
        }
    }

    private func control(_ name: String, value path: WritableKeyPath<ColorAdjustments, Double>,
                         range: ClosedRange<Double>, neutral: Double) -> some View {
        let current = color.adjustments[keyPath: path]
        return HStack(spacing: 6) {
            Text(name).font(.caption).foregroundStyle(.secondary).frame(width: 92, alignment: .leading)
            Slider(value: Binding(get: { current }, set: { value in
                var adjusted = color.adjustments
                adjusted[keyPath: path] = (value * 100).rounded() / 100
                model.setColorAdjustments(adjusted, live: true)
            }), in: range, onEditingChanged: { editing in if !editing { model.endGesture() } })
                .accessibilityLabel(name)
                .accessibilityValue(String(format: "%.2f", current))
            Button {
                var adjusted = color.adjustments
                adjusted[keyPath: path] = neutral
                model.setColorAdjustments(adjusted)
            } label: { Image(systemName: "arrow.counterclockwise") }
                .buttonStyle(.borderless)
                .disabled(current == neutral)
                .help("Reset \(name.lowercased())")
                .accessibilityLabel("Reset \(name.lowercased())")
        }
    }

    private func note(_ text: String, icon: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 5) {
            Image(systemName: icon).foregroundStyle(tint)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .font(.caption2).foregroundStyle(.secondary)
    }
}

/// Choose which recordings get this recording's colour. The look always copies; the
/// recorded colour and conversion only when asked, because they describe how a file
/// was recorded and are wrong for footage recorded another way.
private struct CopyColorSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let source: VideoItem
    @State private var chosen: Set<UUID> = []
    @State private var includeInterpretation = false

    private var candidates: [VideoItem] { model.items.filter { $0.id != source.id && $0.info != nil } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Copy colour from \(source.name)").font(.headline)
            List(candidates) { item in
                Toggle(item.name, isOn: Binding(get: { chosen.contains(item.id) },
                                                set: { if $0 { chosen.insert(item.id) } else { chosen.remove(item.id) } }))
            }
            .frame(minHeight: 140)
            Toggle("Also copy the recorded colour and conversion", isOn: $includeInterpretation)
            Text(includeInterpretation
                 ? "Only use this for recordings made the same way, such as other Pocket 3 D-Log M clips."
                 : "Copies brightness, warmth, contrast and colour strength.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(chosen.count == candidates.count ? "Select None" : "Select All") {
                    chosen = chosen.count == candidates.count ? [] : Set(candidates.map(\.id))
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Copy") {
                    model.copyColor(to: candidates.map(\.id).filter(chosen.contains), includeInterpretation: includeInterpretation)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(chosen.isEmpty)
            }
        }
        .padding(18)
        .frame(width: 420)
    }
}
