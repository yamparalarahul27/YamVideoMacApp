import Foundation
import SwiftUI

struct VoiceSection: View {
    @EnvironmentObject var model: AppModel
    let item: VideoItem
    @State private var draft = VoiceSettings()
    var body: some View {
        InspectorSection("Voice") {
            Toggle("Voice treatment", isOn: $draft.enabled)
            HStack {
                Button("Gentle") { draft = VoiceSettings() }
                Button("Clear") { draft = VoiceSettings(); draft.noiseReduction = 6; draft.harshness = 1.5; draft.sibilance = 0.2; draft.warmth = 0.5 }
            }.controlSize(.small)
            control("Noise reduction", $draft.noiseReduction, 0...24, unit: "dB")
            control("Soften harshness", $draft.harshness, 0...8, unit: "dB")
            control("Soften S sounds", $draft.sibilance, 0...1)
            control("Warmth", $draft.warmth, 0...4, unit: "dB")
            control("Level balance", $draft.compression, 0...1)
            control("Output gain", $draft.gain, -12...6, unit: "dB")
            control("Cut audio smoothing", $draft.cutFadeMS, 0...80, unit: "ms")
            HStack {
                Button("Apply voice settings") { model.applyVoice(draft, to: item.id) }.disabled(model.voicePreparing != nil || model.isConverting)
                if let current = item.voice {
                    Button(current.settings.enabled ? "Hear original" : "Hear treated") {
                        var settings = current.settings; settings.enabled.toggle(); model.applyVoice(settings, to: item.id)
                    }.disabled(model.voicePreparing != nil || model.isConverting)
                }
            }.controlSize(.small)
            if model.voicePreparing == item.id { ProgressView("Preparing voice…") }
            if let error = model.voiceError { Text(error).font(.caption).foregroundStyle(.red) }
            if let voice = item.voice, voice.settings.enabled, let url = voice.rendered, !FileManager.default.fileExists(atPath: url.path) {
                Text("Prepared audio is missing. Apply these settings to rebuild it.").font(.caption).foregroundStyle(.orange)
            }
            Text("Pitch stays natural. Original/treated comparison matches average loudness. Tone and cut smoothing apply to Recording, Movie and export. Export Loudness still controls final delivery level. Apply after adjusting; Undo restores the previous sound.").font(.caption2).foregroundStyle(.secondary)
        }
        .onAppear { draft = item.voice?.settings ?? VoiceSettings() }
        .onChange(of: item.voice) { _, value in draft = value?.settings ?? VoiceSettings() }
    }
    private func control(_ label: String, _ value: Binding<Double>, _ range: ClosedRange<Double>, unit: String = "%") -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack { Text(label); Spacer(); Text(unit == "%" ? String(format: "%.0f%%", value.wrappedValue * 100) : String(format: "%.1f %@", value.wrappedValue, unit)).monospacedDigit() }.font(.caption)
            Slider(value: value, in: range).accessibilityLabel(label)
        }
    }
}
