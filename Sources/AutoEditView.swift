import SwiftUI

/// Auto Edit: the answers asked before an edit (transcript model and language, how tight to
/// cut, captions, loudness), saved in the project, and the button that edits the selected
/// recording by them.
struct AutoEditSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingDownload: TranscriptModel?

    private var options: AutoEditOptions { model.autoEditOptions }
    private var item: VideoItem? { model.selectedItem.flatMap { $0.info == nil ? nil : $0 } }
    private var busy: Bool { model.autoEditRun != nil }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Auto Edit").font(.title2.weight(.semibold))
                if let item { Text(item.name).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
                Spacer()
            }
            .padding(.horizontal, 18).padding(.vertical, 14)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("How YamVideo edits a recording for you. These answers are saved with the project, and agents follow them too.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    transcript
                    cuts
                    captions
                    audio
                }
                .padding(18)
                .disabled(busy)
            }
            Divider()
            footer.padding(14)
        }
        .frame(width: 540, height: 680)
        .confirmationDialog("Download the \(confirmingDownload?.label ?? "") model?", isPresented: Binding(
            get: { confirmingDownload != nil }, set: { if !$0 { confirmingDownload = nil } }), presenting: confirmingDownload) { choice in
            Button("Download \(choice.sizeLabel)") { model.downloadModel(choice) }
            Button("Cancel", role: .cancel) {}
        } message: { choice in
            Text("YamVideo transcribes on this Mac with whisper.cpp (MIT). The \(choice.label) model is \(choice.sizeLabel), "
                 + "downloaded once from whisper.cpp's page on Hugging Face and checked against its published checksum. "
                 + "Your recordings never leave this Mac.")
        }
        .sheet(item: $model.autoEditReview) { plan in
            if let clip = model.items.first(where: { $0.id == plan.clip }), let overview = plan.overview {
                SilenceReviewView(clip: clip, overview: overview, stumbles: plan.stumbles, initialRule: plan.style.pauses,
                                  includeStumbles: true, plan: plan)
                    .environmentObject(model)
            }
        }
    }

    // MARK: Sections

    private var transcript: some View {
        InspectorSection("Transcript") {
            if Whisper.cliPath == nil {
                warning("Transcribing needs whisper.cpp. Install it with Homebrew, then reopen Auto Edit:\nbrew install whisper-cpp")
            }
            ForEach(TranscriptModel.allCases) { choice in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: options.model == choice ? "largecircle.fill.circle" : "circle")
                        .foregroundStyle(options.model == choice ? Color.accentColor : .secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(choice.label) · \(choice.sizeLabel)").font(.callout.weight(.medium))
                        Text(choice.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    modelStatus(choice)
                }
                .contentShape(Rectangle())
                .onTapGesture { model.setAutoEditOptions { $0.model = choice } }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(options.model == choice ? [.isButton, .isSelected] : .isButton)
            }
            Picker("Language", selection: Binding(get: { options.language }, set: { language in model.setAutoEditOptions { $0.language = language } })) {
                ForEach(AutoEditOptions.languages, id: \.self) { Text(AutoEditOptions.languageName($0)).tag($0) }
            }
            .frame(maxWidth: 320)
            if options.model.englishOnly {
                Text("Base (English) understands English only; another language switches to Large v3 Turbo.")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            if let error = model.modelDownloadError { warning(error) }
            if let item { recordingTranscript(item) }
        }
    }

    @ViewBuilder private func modelStatus(_ choice: TranscriptModel) -> some View {
        if let download = model.modelDownload, download.model == choice {
            HStack(spacing: 6) {
                ProgressView(value: download.fraction).frame(width: 80)
                Button("Cancel") { model.cancelModelDownload() }.controlSize(.small)
            }
        } else if Whisper.hasModel(choice) {
            Label("Downloaded", systemImage: "checkmark.circle.fill").labelStyle(.titleAndIcon)
                .font(.caption).foregroundStyle(.green)
        } else {
            Button("Download…") { confirmingDownload = choice }
                .controlSize(.small)
                .disabled(model.modelDownload != nil)
        }
    }

    @ViewBuilder private func recordingTranscript(_ item: VideoItem) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "text.quote").foregroundStyle(.secondary)
            if let words = item.transcript {
                Text("\(item.name): \(words.words.count) words (\(TranscriptModel(rawValue: words.model)?.label ?? words.model), \(AutoEditOptions.languageName(words.language))).")
                    .font(.caption).lineLimit(2).truncationMode(.middle)
                Spacer()
                Button("Transcribe Again") { model.transcribeSelected() }.controlSize(.small)
                    .disabled(!canTranscribe)
                Button("Remove") { model.removeTranscript() }.controlSize(.small)
            } else if item.info?.hasAudio == false {
                Text("\(item.name) has no audio to transcribe.").font(.caption).foregroundStyle(.secondary)
                Spacer()
            } else {
                Text("\(item.name) is not transcribed yet. Auto Edit transcribes it when the cuts or captions need the words.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Transcribe Now") { model.transcribeSelected() }.controlSize(.small).disabled(!canTranscribe)
            }
        }
    }

    private var canTranscribe: Bool { Whisper.status(options.model) == .ready && !busy }

    private var cuts: some View {
        InspectorSection("Cuts") {
            ForEach(CutStyle.allCases) { style in
                choiceRow(style.label, style.detail, selected: options.cutStyle == style) {
                    model.setAutoEditOptions { $0.cutStyle = style }
                }
            }
        }
    }

    private var captions: some View {
        InspectorSection("Captions") {
            ForEach(CaptionUse.allCases) { use in
                choiceRow(use.label, use.detail, selected: options.captions == use) {
                    model.setAutoEditOptions { $0.captions = use }
                }
            }
            if let file = item?.subtitles, options.captions != .off {
                Text("This recording has its own caption file, \(file.lastPathComponent), which is used instead of the transcript.")
                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var audio: some View {
        InspectorSection("Audio") {
            Toggle("Normalise loudness to \(Loudness.summary)", isOn: Binding(
                get: { options.normaliseAudio }, set: { on in model.setAutoEditOptions { $0.normaliseAudio = on } }))
            Text("YouTube plays everything at about -14 LUFS, so a quiet recording would otherwise sound quieter than the videos around it.")
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func choiceRow(_ title: String, _ detail: String, selected: Bool, choose: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(selected ? Color.accentColor : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: choose)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 10) {
            status
            Spacer()
            if busy {
                Button("Stop") { model.cancelAutoEdit() }
            }
            Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            Button(options.cutStyle == .review ? "Find Cuts to Review" : "Auto Edit") { model.runAutoEdit() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(item == nil || busy || model.isConverting || model.isMovieMode)
                .help("Transcribes if needed, cuts, and sets captions and loudness for the selected recording, as one step you can undo")
        }
    }

    @ViewBuilder private var status: some View {
        if let run = model.autoEditRun {
            HStack(spacing: 8) {
                if let fraction = run.fraction { ProgressView(value: fraction).frame(width: 90) }
                else { ProgressView().controlSize(.small) }
                Text(run.step).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        } else if let error = model.autoEditError {
            Label(error, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange).lineLimit(3)
        } else if let message = model.autoEditMessage {
            Label(message, systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green).lineLimit(3)
        } else if item == nil {
            Text("Select a recording to edit.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func warning(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 5) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(text).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        }
        .font(.caption).foregroundStyle(.secondary)
    }
}
