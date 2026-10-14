import CoreGraphics
import Foundation

/// A whole-frame blur over part of one recording, fading in and out.
///
/// Times are edited-recording seconds — after cuts, reordering and speed changes — and
/// the interval is half-open, `[start, end)`, so two blocks that touch are never both on.
/// It blurs the visible recording after crop and zoom; blur areas stay obscured in both
/// the original and the blurred picture it mixes between.
struct VideoBlurEffect: Identifiable, Codable, Equatable {
    var id = UUID()
    var start: Double
    var end: Double
    /// Gaussian strength as a standard deviation in pixels of a picture whose long side is
    /// 1080; scaled to the cropped frame, so a crop or export size never changes the look.
    var amount = VideoBlurEffect.defaultAmount
    /// How much of the blurred picture shows at full strength: 0 none, 1 all of it.
    var mix = 1.0
    var fadeIn = VideoBlurEffect.defaultFade
    var fadeOut = VideoBlurEffect.defaultFade
    /// Off keeps the block and its place on the timeline but draws nothing.
    var isEnabled = true

    static let amountRange = 0.0...80.0
    static let mixRange = 0.0...1.0
    static let defaultAmount = 24.0
    static let defaultFade = 0.25
    static let defaultDuration = 3.0

    var duration: Double { end - start }

    /// How much of the blurred picture shows at edited time `t`, from 0 to `mix`. The
    /// strength of the blur never ramps; only its share of the picture does.
    func weight(at t: Double) -> Double {
        guard isEnabled, t >= start, t < end else { return 0 }
        let fadeInProgress = fadeIn == 0 ? 1 : min(1, max(0, (t - start) / fadeIn))
        let fadeOutProgress = fadeOut == 0 ? 1 : min(1, max(0, (end - t) / fadeOut))
        let u = min(fadeInProgress, fadeOutProgress)
        return mix * u * u * (3 - 2 * u)
    }

    /// Whether it changes any frame at all. Off, no amount or no mix is an exact bypass.
    var isVisible: Bool { isEnabled && amount > 0 && mix > 0 }

    /// The Gaussian standard deviation for a frame of `size`, in that frame's pixels.
    func sigma(for size: CGSize) -> Double { amount * Double(max(size.width, size.height)) / 1080 }

    /// The same block snapped to the frame cadence, as the reducer stores it.
    func snapped(fps: Double) -> VideoBlurEffect {
        var effect = self
        effect.start = snapToFrame(start, fps: fps)
        effect.end = snapToFrame(end, fps: fps)
        return effect
    }

    /// Everything the timeline needs to hold for this block, or the reason it cannot.
    func problem(duration timeline: Double, fps: Double) -> String? {
        let numbers = [start, end, amount, mix, fadeIn, fadeOut]
        guard numbers.allSatisfy(\.isFinite) else { return "Effect values must be finite numbers." }
        guard start >= 0, end <= timeline + 0.0005 else {
            return "The effect must lie within the edited recording (0–\(String(format: "%.2f", timeline)) s)."
        }
        guard duration >= 1 / max(1, fps) - 0.000001 else { return "An effect must last at least one frame." }
        guard Self.amountRange.contains(amount) else { return "Amount must be from 0 to 80." }
        guard Self.mixRange.contains(mix) else { return "Mix must be from 0 to 1." }
        guard fadeIn >= 0, fadeOut >= 0 else { return "Fades cannot be negative." }
        guard fadeIn + fadeOut <= duration + 0.000001 else {
            return "Fade in and fade out together (\(String(format: "%.2f", fadeIn + fadeOut)) s) must fit in the effect's \(String(format: "%.2f", duration)) s."
        }
        return nil
    }

    func overlaps(_ other: VideoBlurEffect) -> Bool { start < other.end - 0.000001 && other.start < end - 0.000001 }
}

/// Rounds an edited time to the nearest frame boundary.
func snapToFrame(_ time: Double, fps: Double) -> Double {
    let rate = max(1, fps)
    return (time * rate).rounded() / rate
}

/// A named point on one recording's edited timeline.
struct TimelineMarker: Identifiable, Codable, Equatable {
    enum Color: String, Codable, CaseIterable, Identifiable {
        case red, orange, yellow, green, blue, purple
        var id: String { rawValue }
        var label: String { rawValue.capitalized }
    }

    var id = UUID()
    /// Edited-recording seconds.
    var time: Double
    var label = ""
    var color = Color.blue

    static let maximumLabel = 80

    func problem(duration timeline: Double) -> String? {
        guard time.isFinite, time >= 0, time <= timeline + 0.0005 else {
            return "A marker must be within the edited recording (0–\(String(format: "%.2f", timeline)) s)."
        }
        guard label.count <= Self.maximumLabel, !label.contains(where: \.isNewline) else {
            return "A marker label is one line of at most \(Self.maximumLabel) characters."
        }
        return nil
    }
}

// MARK: - Following the footage

extension ClipTimeline {
    /// Where an edited time on `old` lands on this timeline: on the same source frame, or
    /// nil when that footage is gone. The very end stays the very end.
    func carry(_ time: Double, from old: ClipTimeline) -> Double? {
        if time >= old.duration - 0.000001 { return segments.isEmpty ? nil : duration }
        guard let source = old.location(at: time)?.source else { return nil }
        return self.time(forSource: source)
    }

    /// Effects follow the frame they start on; duration and fades stay in playback
    /// seconds, shortened to fit if the recording got shorter. Removed footage removes
    /// the effect, and a collision keeps the earlier block.
    func remap(_ effects: [VideoBlurEffect], from old: ClipTimeline, fps: Double) -> [VideoBlurEffect] {
        let frame = 1 / max(1, fps)
        var moved: [VideoBlurEffect] = []
        for var effect in effects {
            guard let start = carry(effect.start, from: old) else { continue }
            let length = effect.duration
            effect.start = snapToFrame(start, fps: fps)
            effect.end = min(duration, effect.start + length)
            guard effect.duration >= frame - 0.000001 else { continue }
            if effect.fadeIn + effect.fadeOut > effect.duration {
                let scale = effect.duration / (effect.fadeIn + effect.fadeOut)
                effect.fadeIn *= scale; effect.fadeOut *= scale
            }
            moved.append(effect)
        }
        var kept: [VideoBlurEffect] = []
        for effect in moved.sorted(by: { ($0.start, $0.id.uuidString) < ($1.start, $1.id.uuidString) })
        where !kept.contains(where: { $0.overlaps(effect) }) {
            kept.append(effect)
        }
        return kept
    }

    /// Markers stay on their frame, and go with it when it is cut away.
    func remap(_ markers: [TimelineMarker], from old: ClipTimeline) -> [TimelineMarker] {
        markers.compactMap { marker in
            guard let time = carry(marker.time, from: old) else { return nil }
            var moved = marker
            moved.time = time
            return moved
        }
        .sorted { $0.time < $1.time }
    }
}
