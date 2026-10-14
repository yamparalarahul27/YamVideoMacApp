import SwiftUI
import UniformTypeIdentifiers
import YVCore

struct ExportTabView: View {
    @StateObject private var model = ExportModel()
    @State private var showingPicker = false
    @State private var dropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            if model.items.isEmpty {
                emptyState
            } else {
                fileList
                Divider()
                settingsBar
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            handleDrop(providers)
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.accentColor, style: .init(lineWidth: 2, dash: [8, 6]))
                    .padding(8)
                    .background(Color.accentColor.opacity(0.06))
                    .allowsHitTesting(false)
            }
        }
        .fileImporter(isPresented: $showingPicker,
                      allowedContentTypes: [.movie, .quickTimeMovie, .mpeg4Movie, .video],
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { model.add(urls: urls) }
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Drop videos here", systemImage: "arrow.down.doc")
        } description: {
            Text("MOV in, web-ready MP4 out — instant and lossless when the codec allows.\nGIF too, once a range is short enough to deserve one.")
        } actions: {
            Button("Choose Files…") { showingPicker = true }
                .keyboardShortcut("o")
        }
    }

    // MARK: - File list

    private var fileList: some View {
        ScrollView {
            LazyVStack(spacing: 6) {
                ForEach(model.items) { item in
                    ExportRow(item: item, model: model)
                }
            }
            .padding(10)
        }
    }

    // MARK: - Settings bar

    private var settingsBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                Picker("Preset", selection: $model.preset) {
                    ForEach(ExportPreset.allCases) { preset in
                        Text(preset.label).tag(preset)
                    }
                }
                .frame(maxWidth: 320)
                .help(model.preset.help)

                Toggle("Remux when possible", isOn: $model.preferRemux)
                    .help("Stream-copy to MP4 with no quality loss when the codec is already MP4-compatible. Turn off to force a re-encode at the preset above.")

                Spacer()

                Button("Add…") { showingPicker = true }
                Button("Convert All to MP4") { model.convertAll() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.items.contains { $0.status == .ready })
            }

            Divider()

            gifBar
        }
        .padding(12)
    }

    private var gifBar: some View {
        HStack(spacing: 12) {
            Label("GIF", systemImage: "photo.stack")
                .font(.callout.weight(.semibold))

            if model.ffmpegPath != nil {
                TextField("start (1:30)", text: $model.gifStartText)
                    .frame(width: 90)
                TextField("end", text: $model.gifEndText)
                    .frame(width: 90)
                Stepper("fps: \(model.gif.fps)", value: $model.gif.fps, in: 5...30, step: 5)
                Stepper("width: \(model.gif.width)", value: $model.gif.width, in: 320...1280, step: 80)
                Picker("dither", selection: $model.gif.dither) {
                    ForEach(GifSettings.Dither.allCases, id: \.self) { d in
                        Text(d.label).tag(d)
                    }
                }
                .frame(maxWidth: 190)
                Spacer()
                Text("blank range = whole video · per-file button on each row")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("GIF export needs ffmpeg:")
                    .foregroundStyle(.secondary)
                Text(FFmpeg.installHint)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(FFmpeg.installHint, forType: .string)
                }
                Button("Re-check") { model.refreshFFmpeg() }
                Spacer()
            }
        }
        .textFieldStyle(.roundedBorder)
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var found = false
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            found = true
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in model.add(urls: [url]) }
            }
        }
        return found
    }
}

// MARK: - Row

private struct ExportRow: View {
    let item: ExportItem
    @ObservedObject var model: ExportModel

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                infoLine
            }
            Spacer()
            trailing
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private var infoLine: some View {
        if let info = item.info {
            HStack(spacing: 6) {
                if let codec = info.videoCodec {
                    Text(codec)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 5).padding(.vertical, 1.5)
                        .background(item.canRemux ? Color.green.opacity(0.18) : Color.orange.opacity(0.18),
                                    in: Capsule())
                }
                Text("\(info.width)×\(info.height)")
                Text(info.durationText)
                Text(info.sizeText)
                if item.canRemux {
                    Text("→ remux (lossless, instant)").foregroundStyle(.green)
                } else {
                    Text("→ transcode").foregroundStyle(.orange)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        } else {
            Text("probing…").font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var trailing: some View {
        switch item.status {
        case .probing:
            ProgressView().controlSize(.small)

        case .ready:
            HStack(spacing: 8) {
                if model.ffmpegPath != nil, let estimate = model.gifEstimate(for: item) {
                    Button("GIF ~\(estimate)") { model.exportGif(id: item.id) }
                        .help("Palette-optimized GIF at the settings below. Estimate is rough (±2×).")
                }
                Button("→ MP4") { model.convert(id: item.id) }
                    .buttonStyle(.borderedProminent)
                Button(role: .destructive) { model.remove(id: item.id) } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }

        case .working(let progress):
            ProgressView(value: progress)
                .frame(width: 160)

        case .done(let url, let bytes, let remux):
            HStack(spacing: 8) {
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(url.lastPathComponent) · \(MediaInfo.formatBytes(bytes))")
                        .font(.caption)
                    if let input = item.info {
                        Text(savingsText(from: input.fileSizeBytes, to: bytes, remux: remux))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Button("Show") { model.revealInFinder(url) }
                Button("Again") { model.convert(id: item.id) }
                    .help("Convert again (e.g. after changing the preset).")
            }
            .foregroundStyle(.primary)

        case .failed(let message):
            HStack(spacing: 8) {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
                    .frame(maxWidth: 320, alignment: .trailing)
                Button("Retry") { model.convert(id: item.id) }
            }
        }
    }

    private func savingsText(from input: Int64, to output: Int64, remux: Bool) -> String {
        guard input > 0, output > 0 else { return remux ? "remuxed" : "transcoded" }
        let percent = 100.0 * (1.0 - Double(output) / Double(input))
        let verb = remux ? "remuxed" : "transcoded"
        if percent > 1 { return "\(verb) · \(Int(percent))% smaller" }
        if percent < -1 { return "\(verb) · \(Int(-percent))% larger" }
        return verb
    }
}
