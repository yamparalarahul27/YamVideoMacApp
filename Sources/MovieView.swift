import SwiftUI

struct MovieView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var playback: PlaybackController

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Movie").font(.headline)
                    Text("Combine your recordings, including their cuts and effects.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Picker("Canvas", selection: Binding(get: { model.movieSettings.canvas }, set: { model.changeMovieCanvas($0) })) {
                    ForEach(MovieCanvas.allCases) { Text($0.label).tag($0) }
                }.frame(width: 205)
            }.padding(14)
            Divider()
            if let plan = try? model.moviePlan() {
                PlaybackCanvas(playback: playback).frame(maxHeight: .infinity)
                HStack(spacing: 10) {
                    Button { model.stepFrame(-1) } label: { Image(systemName: "backward.frame") }
                        .accessibilityLabel("Previous movie frame")
                    Button { model.toggleMoviePlayback() } label: { Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill") }
                        .accessibilityLabel(playback.isPlaying ? "Pause movie" : "Play movie")
                    Button { model.stepFrame(1) } label: { Image(systemName: "forward.frame") }
                        .accessibilityLabel("Next movie frame")
                    Slider(value: Binding(get: { model.movieTime }, set: { playback.pause(); model.seekMovie(to: $0) }), in: 0...max(0.001, plan.duration))
                        .accessibilityLabel("Movie playhead")
                    Text("\(timelineTime(model.movieTime)) / \(timelineTime(plan.duration))")
                        .font(.system(.caption, design: .monospaced))
                }.buttonStyle(.borderless).padding(.horizontal, 16).padding(.vertical, 8)
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        HStack(spacing: 2) {
                            ForEach(plan.clips) { clip in
                                Button {
                                    playback.pause()
                                    model.selection = clip.id
                                    model.seekMovie(to: plan.offset(of: clip.id))
                                } label: {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(clip.name).lineLimit(1)
                                        Text(timelineTime(clip.editedDuration)).font(.system(size: 9, design: .monospaced))
                                    }
                                    .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                                    .background(Color.accentColor.opacity(0.22), in: RoundedRectangle(cornerRadius: 5))
                                }.buttonStyle(.plain)
                                    .frame(width: max(1, (geo.size.width - Double(max(0, plan.clips.count - 1)) * 2) * clip.editedDuration / plan.duration))
                            }
                        }
                        Rectangle().fill(Color.primary).frame(width: 1.5)
                            .offset(x: min(geo.size.width - 1, geo.size.width * model.movieTime / plan.duration))
                            .allowsHitTesting(false)
                    }
                }.frame(height: 45).padding(.horizontal, 16).padding(.bottom, 12)
            } else {
                ContentUnavailableView("Add recordings to your movie", systemImage: "film.stack",
                                       description: Text("Include a recording below. Missing source files must be located before playback."))
                    .frame(maxHeight: .infinity)
            }
            Divider()
            HStack {
                Text("RECORDINGS").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                if let plan = try? model.moviePlan() {
                    Text("\(Int(plan.size.width))×\(Int(plan.size.height)) · \(String(format: "%.2f", plan.fps)) fps")
                        .font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary)
                }
            }.padding(.horizontal, 16).padding(.top, 12)
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(Array(model.items.enumerated()), id: \.element.id) { index, clip in
                        HStack(spacing: 9) {
                            Toggle("Include \(clip.name)", isOn: Binding(get: { clip.includedInMovie }, set: { model.includeInMovie(clip.id, included: $0) })).labelsHidden()
                            Text("\(index + 1)").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 18)
                            Text(clip.name).font(.callout).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Text(timelineTime(clip.editedDuration)).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                            Button { model.moveMovieClip(clip.id, by: -1) } label: { Image(systemName: "arrow.up") }
                                .disabled(index == 0).accessibilityLabel("Move \(clip.name) earlier")
                            Button { model.moveMovieClip(clip.id, by: 1) } label: { Image(systemName: "arrow.down") }
                                .disabled(index == model.items.count - 1).accessibilityLabel("Move \(clip.name) later")
                            Button("Edit") { model.editMovieClip(clip.id) }
                        }.controlSize(.small).padding(8)
                            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 6))
                    }
                }.padding(.horizontal, 16).padding(.vertical, 8)
            }.frame(height: 145)
            if let progress = model.movieProgress {
                ProgressView("Exporting movie…", value: progress).padding(16)
            } else if let output = model.movieOutput {
                HStack {
                    Label("Movie exported", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    Spacer()
                    Button("Show in Finder") { model.reveal(output) }
                }.font(.caption).padding(16)
            }
        }
        .onAppear { model.prepareMovie(play: false) }
        .onChange(of: model.project.clips) { _, _ in
            model.movieOutput = nil
            model.prepareMovie(play: false)
        }
        .onChange(of: model.settings) { _, _ in
            model.movieOutput = nil
            model.prepareMovie(play: false)
        }
    }
}
