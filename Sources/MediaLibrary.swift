import Foundation

// MARK: - What the Media panel adds

/// Something the Media panel adds to the recording, by its + button or by a drag onto the
/// timeline. Its `id` is what a drag carries.
enum MediaAsset: Equatable {
    case namePlate, titleCard, kineticText, sectionCard, callout, endScreen
    case logo(String)
    case blurArea, fullFrameBlur, zoom, screenZoom, marker

    static let dragPrefix = "yamvideo-asset:"

    var id: String {
        switch self {
        case .namePlate: return "namePlate"
        case .titleCard: return "titleCard"
        case .kineticText: return "kineticText"
        case .sectionCard: return "sectionCard"
        case .callout: return "callout"
        case .endScreen: return "endScreen"
        case .logo(let name): return "logo:" + name
        case .blurArea: return "blurArea"
        case .fullFrameBlur: return "fullFrameBlur"
        case .zoom: return "zoom"
        case .screenZoom: return "screenZoom"
        case .marker: return "marker"
        }
    }

    /// What a drag carries: a prefix, so a drop of other text never adds anything.
    var dragText: String { Self.dragPrefix + id }

    init?(dragText: String) {
        guard dragText.hasPrefix(Self.dragPrefix) else { return nil }
        let id = String(dragText.dropFirst(Self.dragPrefix.count))
        if id.hasPrefix("logo:") { self = .logo(String(id.dropFirst(5))); return }
        let all: [MediaAsset] = [.namePlate, .titleCard, .kineticText, .sectionCard, .callout, .endScreen,
                                 .blurArea, .fullFrameBlur, .zoom, .screenZoom, .marker]
        guard let match = all.first(where: { $0.id == id }) else { return nil }
        self = match
    }
}

extension AppModel {
    /// Adds an asset at the playhead, or at `time` when it is dropped on the timeline.
    func add(_ asset: MediaAsset, at time: Double? = nil) {
        guard let item = selectedItem, item.info != nil, !isMovieMode else { statusMessage = "Select a recording first."; return }
        if let time { playback.pause(); setPreviewFraction(min(max(time, 0), item.editedDuration) / max(0.001, item.editedDuration)) }
        switch asset {
        case .namePlate:
            addStarter(.namePlate, props: ["title": .string("Your name"), "detail": .string("What you do")], label: "Add Name Plate")
        case .titleCard:
            addStarter(.titleCard, props: ["kicker": .string("New video"), "title": .string("Your title")], label: "Add Title Card")
        case .kineticText: addKineticText()
        case .sectionCard: addSectionCard()
        case .callout:
            guard item.screen != nil else { statusMessage = "Add a screen recording first, in Media."; return }
            addCallout()
        case .endScreen: addEndScreen()
        case .logo(let name): addLogoBadge(named: name)
        case .blurArea:
            addDefaultRegion()
            beginBlurAreas(selecting: selectedRegionID)
        case .fullFrameBlur: addBlurEffect()
        case .zoom: addZoomFromTimeline()
        case .screenZoom:
            guard item.screen != nil else { statusMessage = "Add a screen recording first, in Media."; return }
            addScreenZoomAtPlayhead()
        case .marker: addMarkerAtPlayhead()
        }
    }

    /// A graphic with words to replace, 4 s from the playhead.
    private func addStarter(_ kind: GraphicKind, props: [String: JSONValue], label: String) {
        guard let item = selectedItem else { return }
        let start = min(max(0, previewTime), max(0, item.editedDuration - 1))
        let graphic = Graphic(kind: kind, start: start, end: min(item.editedDuration, start + 4), props: props)
        switch perform([.addGraphic(clip: item.id, graphic: graphic)], label: label) {
        case .success:
            selectedGraphicID = graphic.id
            statusMessage = "Added a \(kind.label.lowercased()). Change its words in the inspector."
        case .failure(let error): statusMessage = error.message
        }
    }

    /// A logo badge from the library, next to the speaker for 4 s from the playhead.
    func addLogoBadge(named name: String, library: [LogoLibrary.Logo] = LogoLibrary.load()) {
        guard let item = selectedItem, let logo = library.first(where: { $0.name == name }) else {
            statusMessage = "No logo named \(name) in the library."; return
        }
        let start = min(max(0, previewTime), max(0, item.editedDuration - 1))
        let props: [String: JSONValue] = ["logos": .array([.object(["image": .string(LogoLibrary.path(of: logo)),
                                                                     "label": .string(logo.name), "at": .number(0)])])]
        let graphic = Graphic(kind: .logoBadge, start: start, end: min(item.editedDuration, start + 4), props: props)
        switch perform([.addGraphic(clip: item.id, graphic: graphic)], label: "Add \(logo.name) Logo") {
        case .success: selectedGraphicID = graphic.id
        case .failure(let error): statusMessage = error.message
        }
    }
}

// MARK: - The Captions track

/// One caption on the edited timeline. Captions from the transcript can be edited here;
/// captions from a file are shown as they are.
struct CaptionCue: Equatable, Identifiable {
    let index: Int
    let start: Double
    let end: Double
    let text: String
    /// Where the caption is in the source, to find its words in the transcript.
    let sourceStart: Double
    let sourceEnd: Double
    let editable: Bool
    var id: Int { index }
}

extension VideoItem {
    /// The captions as the export shows them, on the edited timeline: from the caption
    /// file when there is one, else from the transcript.
    func captionCues() -> [CaptionCue] {
        if let subtitles {
            guard let text = try? String(contentsOf: subtitles, encoding: .utf8),
                  let parsed = try? Captions.parse(text) else { return [] }
            return Captions.edited(parsed, timeline: timeline).enumerated().map { index, caption in
                CaptionCue(index: index, start: caption.start, end: caption.end, text: caption.text,
                           sourceStart: caption.start, sourceEnd: caption.end, editable: false)
            }
        }
        guard let transcript, !transcript.words.isEmpty else { return [] }
        let source = transcript.captions(timeline: timeline)
        var cues: [CaptionCue] = []
        for caption in source {
            for placed in Captions.edited([caption], timeline: timeline) {
                cues.append(CaptionCue(index: cues.count, start: placed.start, end: placed.end, text: placed.text,
                                       sourceStart: caption.start, sourceEnd: caption.end, editable: true))
            }
        }
        return cues
    }

    /// The transcript with one caption's words replaced by `text`, spread over the time
    /// the caption's words took. Nil when the caption has no words in the transcript.
    func transcript(replacing cue: CaptionCue, with text: String) -> Transcript? {
        guard var transcript, cue.editable else { return nil }
        let spoken = text.split(whereSeparator: \.isWhitespace).map(String.init)
        let kept = Set(transcript.keptWords(timeline).map { "\($0.word.start)-\($0.word.text)" })
        let indices = transcript.words.indices.filter { index in
            let word = transcript.words[index]
            return word.start >= cue.sourceStart - 0.000001 && word.start < cue.sourceEnd && kept.contains("\(word.start)-\(word.text)")
        }
        guard let first = indices.first, let last = indices.last, !spoken.isEmpty else { return nil }
        let old = transcript.words[first...last]
        if spoken.count == old.count {
            for (offset, index) in (first...last).enumerated() { transcript.words[index].text = spoken[offset] }
            return transcript
        }
        // A different number of words: the new words share the old words' time evenly.
        let start = old.first!.start, end = max(old.last!.end, start + 0.01)
        let step = (end - start) / Double(spoken.count)
        let replaced = spoken.enumerated().map { offset, word in
            TranscriptWord(text: word, start: start + Double(offset) * step, end: start + Double(offset + 1) * step)
        }
        transcript.words.replaceSubrange(first...last, with: replaced)
        return transcript
    }
}

extension AppModel {
    var selectedCaption: CaptionCue? {
        guard let selectedCaptionIndex, let item = selectedItem else { return nil }
        return item.captionCues().first { $0.index == selectedCaptionIndex }
    }

    /// A caption's words fixed in the transcript, as one undo step. Every export, the
    /// SRT and burned-in captions take the fix.
    func setCaptionText(_ cue: CaptionCue, to text: String) {
        guard let item = selectedItem else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != cue.text else { return }
        guard cue.editable else {
            statusMessage = "These captions come from a file. Edit the file, or use captions from the transcript."
            return
        }
        guard let transcript = item.transcript(replacing: cue, with: trimmed) else {
            statusMessage = trimmed.isEmpty ? "A caption needs at least one word. Cut the section to remove what is said."
                : "That caption has no words in the transcript to change."
            return
        }
        if case .failure(let error) = perform([.setTranscript(clip: item.id, transcript: transcript)], label: "Edit Caption") {
            statusMessage = error.message
        } else {
            statusMessage = "Caption changed. The transcript keeps it for every export."
        }
    }
}

// MARK: - Pauses on the Audio track

extension AudioOverview {
    /// The quiet parts still in the edit, on the edited timeline: what Auto Edit's tight
    /// rule calls a pause, shown on the Audio track so you can cut on them.
    func pauses(in timeline: ClipTimeline, fps: Double) -> [ClosedRange<Double>] {
        let rule = PauseRule.tight
        return cuts(in: timeline, fps: fps, threshold: rule.threshold, minimum: rule.minimum, padding: 0)
            .filter { $0.duration > 0 }
            .map { $0.timelineStart...($0.timelineStart + $0.duration) }
    }
}
