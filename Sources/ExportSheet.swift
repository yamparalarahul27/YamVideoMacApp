import SwiftUI

/// What an export covers.
enum ExportScope: String, CaseIterable, Identifiable {
    case selected, all, movie
    var id: String { rawValue }
    var label: String {
        switch self {
        case .selected: return "Selected recording"
        case .all: return "All recordings"
        case .movie: return "Movie"
        }
    }
}

/// One Export button opens this: what to export, where, and how. Output settings live
/// here rather than beside the editor, because they only matter when exporting.
struct ExportSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State var scope: ExportScope
    @State private var showCommand = false

    private var settingsBinding: Binding<ExportSettings> {
        Binding(get: { model.settings }, set: { model.updateSettings($0) })
    }
    /// For sliders and text: one undo step when the slider is released or the field submitted.
    private var liveSettingsBinding: Binding<ExportSettings> {
        Binding(get: { model.settings }, set: { model.updateSettings($0, live: true) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Export").font(.title2.weight(.semibold))
                Picker("Export", selection: $scope) {
                    ForEach(ExportScope.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text(summary).font(.caption).foregroundStyle(.secondary)
            }
            .padding(18)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    InspectorSection("Format") {
                        Picker("Format", selection: settingsBinding.format) {
                            ForEach(OutputFormat.allCases) { Text($0.label).tag($0) }
                        }
                        .labelsHidden()
                        Text(model.settings.format.detail).font(.caption2).foregroundStyle(.secondary)
                        if model.settings.format == .webp, !model.webpAvailable {
                            warning("This ffmpeg was built without libwebp and cannot write WebP. Run brew install ffmpeg-full and relaunch, or export a GIF instead.")
                        }
                    }
                    if model.settings.format.isAnimation { animationSection } else { videoSection }
                    if model.settings.format == .mp4 { audioSection }
                    destination
                    DisclosureGroup(isExpanded: $showCommand) {
                        if let command = model.previewCommand {
                            Text(command)
                                .font(.system(size: 10, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(6)
                                .background(RoundedRectangle(cornerRadius: 4).fill(Color.black.opacity(0.06)))
                        } else {
                            Text("Select a recording to see the command.").font(.caption).foregroundStyle(.secondary)
                        }
                    } label: {
                        Text("ffmpeg command").font(.caption.weight(.semibold))
                    }
                }
                .padding(18)
            }
            Divider()
            HStack {
                Text("Exports never change your source recordings.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(scope == .movie ? "Export Movie…" : "Export") { export() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canExport)
            }
            .padding(14)
        }
        .frame(width: 520, height: 640)
    }

    private var canExport: Bool {
        guard model.toolsAvailable, !model.isConverting else { return false }
        switch scope {
        case .selected: return model.selectedItem?.info != nil
        case .all: return model.convertibleCount > 0
        case .movie: return (try? model.moviePlan()) != nil
        }
    }

    private var summary: String {
        let quality = model.settings.format.isAnimation
            ? "\(model.settings.format.label) · \(model.settings.frameRate.label)"
            : "\(model.settings.format.label) · \(model.settings.qualityDescription)"
        switch scope {
        case .selected:
            return model.selectedItem.map { "\($0.name) · \(quality)" } ?? "Select a recording first."
        case .all:
            return "\(model.convertibleCount) recording\(model.convertibleCount == 1 ? "" : "s"), each to its own file · \(quality)"
        case .movie:
            if let plan = try? model.moviePlan() {
                return "\(plan.clips.count) recordings joined · \(Int(plan.size.width))×\(Int(plan.size.height)) · \(timelineTime(plan.duration)) · \(quality)"
            }
            return "Include at least one loaded recording in the movie."
        }
    }

    private func export() {
        dismiss()
        switch scope {
        case .selected: model.convertSelected()
        case .all: model.convertAll()
        // The save panel is a separate window; let the sheet close first.
        case .movie: DispatchQueue.main.async { model.promptForMovieExport() }
        }
    }

    // MARK: Sections

    private var videoSection: some View {
        InspectorSection("Video") {
            Picker("Encoder", selection: settingsBinding.encoder) {
                ForEach(VideoEncoder.allCases) { Text($0.label).tag($0) }
            }
            .labelsHidden()
            qualitySlider
            if !model.settings.encoder.isHardware {
                Picker("Speed", selection: settingsBinding.preset) {
                    ForEach(ExportSettings.presets, id: \.self) { Text($0).tag($0) }
                }
            }
            scalePicker
        }
    }

    private var animationSection: some View {
        InspectorSection(model.settings.format == .gif ? "GIF" : "WebP") {
            Picker("Frame rate", selection: settingsBinding.frameRate) {
                ForEach(AnimationFrameRate.allCases) { Text($0.label).tag($0) }
            }
            .labelsHidden()
            scalePicker
            if let hint = animationSizeHint {
                Text(hint).font(.caption2).foregroundStyle(.secondary)
            }
            if model.settings.format == .gif {
                Picker("Colours", selection: settingsBinding.gifColors) {
                    ForEach(GIFColors.allCases) { Text($0.label).tag($0) }
                }
                .labelsHidden()
                Picker("Dither", selection: settingsBinding.gifDither) {
                    ForEach(GIFDither.allCases) { Text($0.label).tag($0) }
                }
                .labelsHidden()
                Text(model.settings.gifDither.detail).font(.caption2).foregroundStyle(.secondary)
            } else {
                if !model.settings.webpLossless { qualitySlider }
                Toggle("Lossless", isOn: settingsBinding.webpLossless).controlSize(.small)
                Text(model.settings.webpLossless
                     ? "Pixel-exact, and much bigger. Worth it for text and flat UI."
                     : "Lossy, like a JPEG per frame. Right for anything photographic.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Toggle("Loop forever", isOn: settingsBinding.loopForever).controlSize(.small)
            Text("Neither format carries audio, so the sound is dropped.").font(.caption2).foregroundStyle(.tertiary)
        }
    }

    private var audioSection: some View {
        InspectorSection("Audio") {
            if scope == .movie, model.settings.audio != .none {
                Text("Movies use AAC audio, with silence for recordings without sound.").font(.caption).foregroundStyle(.secondary)
            } else if model.selectedItem?.segments != nil, model.settings.audio == .copy {
                Text("Timeline cuts require audio encoding. Export will use AAC to keep cuts in sync.").font(.caption).foregroundStyle(.secondary)
            }
            Picker("Audio", selection: settingsBinding.audio) {
                ForEach(AudioMode.allCases) { Text($0.label).tag($0) }
            }
            .labelsHidden()
            if scope != .movie, model.settings.audio == .copy, let info = model.selectedItem?.info,
               info.hasAudio, !info.audioIsMP4Compatible {
                warning("This recording's audio is \(info.audioCodec ?? "uncompressed"). Copying it into MP4 produces a file QuickTime and Safari cannot play — choose AAC instead.")
            } else if model.settings.audio == .normalised {
                Text("Measures each recording, then encodes it to \(Loudness.summary) — what YouTube, Instagram and TikTok normalise toward, so they leave it alone.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var destination: some View {
        InspectorSection("Destination") {
            if scope == .movie {
                Text("Choose the movie's name and location after you click Export Movie.").font(.caption).foregroundStyle(.secondary)
            } else {
                HStack(spacing: 6) {
                    Text(model.settings.outputFolder?.lastPathComponent ?? "Alongside each original")
                        .font(.caption).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Choose…") { model.chooseOutputFolder() }.controlSize(.small)
                    if model.settings.outputFolder != nil {
                        Button { settingsBinding.wrappedValue.outputFolder = nil } label: { Image(systemName: "xmark.circle") }
                            .buttonStyle(.borderless).help("Save next to each source file").accessibilityLabel("Save next to each source file")
                    }
                }
                HStack(spacing: 6) {
                    Text("Name suffix").font(.caption).foregroundStyle(.secondary)
                    TextField("-converted", text: liveSettingsBinding.suffix)
                        .onSubmit { model.endGesture() }
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.caption, design: .monospaced))
                }
                Text("Existing files are never overwritten; a number is added instead.").font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    private var qualitySlider: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("Quality").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(model.settings.qualityDescription).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
            }
            Slider(value: liveSettingsBinding.quality, in: 0...100, step: 5) {
                EmptyView()
            } minimumValueLabel: {
                Text("small").font(.caption2).foregroundStyle(.tertiary)
            } maximumValueLabel: {
                Text("best").font(.caption2).foregroundStyle(.tertiary)
            } onEditingChanged: { editing in
                if !editing { model.endGesture() }
            }
            .accessibilityLabel("Quality")
        }
    }

    private var scalePicker: some View {
        Picker("Size", selection: settingsBinding.sizeLimit) {
            ForEach(SizeLimit.allCases) { Text($0.label).tag($0) }
        }
    }

    /// The usual mistake is a 1080p GIF and a 60 MB file.
    private var animationSizeHint: String? {
        guard model.settings.format.isAnimation, let item = model.selectedItem, let info = item.info else { return nil }
        let crop = (item.crop ?? info.fullFrame).evenClamped(in: info.fullFrame)
        let size = FFmpeg.scaledSize(for: crop.size, limit: model.settings.sizeLimit) ?? crop.size
        guard max(size.width, size.height) > 800 else { return nil }
        return "\(Int(size.width))×\(Int(size.height)) is large for a \(model.settings.format.label.lowercased()) — capping the long side at 640 px or less keeps the file manageable."
    }

    private func warning(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 5) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .font(.caption2).foregroundStyle(.secondary)
    }
}
