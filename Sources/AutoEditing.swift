import Foundation

/// What the owner's auto edit is doing, for the sheet's progress line.
struct AutoEditRun: Equatable {
    var clip: UUID
    var step: String
    /// 0–1 when the step can say how far it is.
    var fraction: Double?
}

/// What an auto edit of one recording does, worked out before anything changes: the cuts
/// for its style, and the export settings with its captions and loudness choices.
struct AutoEditPlan: Identifiable {
    var id = UUID()
    var clip: UUID
    var style: CutStyle
    /// The sections the plan was made against; applying refuses if they have changed.
    var timeline: ClipTimeline
    var overview: AudioOverview?
    var stumbles: [Stumble]
    var cuts: [SilenceCut]
    var settings: ExportSettings
    var hasTranscript: Bool

    var includedCuts: [SilenceCut] { cuts.filter(\.included) }
    var savedSeconds: Double { includedCuts.reduce(0) { $0 + $1.duration } }
    var sections: [TimelineSegment] { timeline.removing(includedCuts).segments }

    /// "Cut 12 pauses and 3 stumbles, 0:41 shorter."
    var summary: String {
        let cuts = includedCuts
        guard !cuts.isEmpty else { return "Nothing to cut." }
        let stumbles = cuts.reduce(0) { $0 + $1.stumbles.count }
        let pauses = cuts.filter(\.pause).count
        var parts: [String] = []
        if pauses > 0 { parts.append("\(pauses) pause\(pauses == 1 ? "" : "s")") }
        if stumbles > 0 { parts.append("\(stumbles) stumble\(stumbles == 1 ? "" : "s")") }
        return "Cut \(parts.joined(separator: " and ")), \(timelineTime(savedSeconds)) shorter."
    }
}

@MainActor
extension AppModel {
    /// The project's answers, or the first video's when none are saved yet.
    var autoEditOptions: AutoEditOptions { autoEdit ?? AutoEditOptions() }

    /// One change to the answers, as one undo step. Base (English) understands English
    /// only, so choosing it sets the language to English, and choosing another language
    /// switches to Large v3 Turbo.
    func setAutoEditOptions(_ change: (inout AutoEditOptions) -> Void) {
        let before = autoEditOptions
        var options = before
        change(&options)
        if options.model.englishOnly, options.language != "en" {
            if options.model != before.model { options.language = "en" } else { options.model = .largeV3Turbo }
        }
        guard options != before || autoEdit == nil else { return }
        if case .failure(let error) = perform([.setAutoEditOptions(options)], label: "Auto Edit Options") {
            statusMessage = error.message
        }
    }

    /// Whether this edit needs the recording's words: to find stumbles, or to make captions
    /// when the recording has no caption file of its own.
    func needsTranscript(_ clip: ProjectClip, options: AutoEditOptions, style: CutStyle? = nil) -> Bool {
        guard clip.info?.hasAudio == true else { return false }
        return (style ?? options.cutStyle).cutsStumbles || (options.captions.uploads && clip.subtitles == nil)
    }

    // MARK: Transcribing

    /// Transcribes a recording with whisper.cpp and stores the words, as its own undo step,
    /// so undoing a later auto edit keeps them.
    @discardableResult
    func transcribe(_ clipID: UUID, model: TranscriptModel, language: String, origin: EditOrigin,
                    progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> (transcript: Transcript, receipt: EditReceipt) {
        guard let clip = committedProject.clips.first(where: { $0.id == clipID }), let info = clip.info else {
            throw EditError(code: .missingMedia, message: "That recording is still loading.")
        }
        guard info.hasAudio else { throw EditError.invalid("\(clip.url.lastPathComponent) has no audio to transcribe.") }
        var options = AutoEditOptions(); options.model = model; options.language = language
        if let problem = options.problem { throw EditError.invalid(problem) }
        let key = [clip.url.standardizedFileURL.path, String(info.duration), model.rawValue, language].joined(separator: "|")
        let transcript: Transcript
        if let cached = transcriptCache[key] {
            transcript = cached
        } else {
            transcript = try await Whisper.transcribe(clip.url, duration: info.duration, model: model, language: language, progress: progress)
            transcriptCache[key] = transcript
        }
        try Task.checkCancellation()
        switch perform([.setTranscript(clip: clipID, transcript: transcript)], label: "Transcribe", origin: origin) {
        case .success(let receipt): return (transcript, receipt)
        case .failure(let error): throw error
        }
    }

    // MARK: Planning and applying

    /// Reads the recording's audio and works out the cuts for `style` (or the project's),
    /// with stumbles from its transcript when the style cuts them. Changes nothing.
    func planAutoEdit(_ clipID: UUID, options: AutoEditOptions, style: CutStyle? = nil) async throws -> AutoEditPlan {
        guard let clip = committedProject.clips.first(where: { $0.id == clipID }), let info = clip.info else {
            throw EditError(code: .missingMedia, message: "That recording is still loading.")
        }
        let style = style ?? options.cutStyle
        var overview: AudioOverview?
        var stumbles: [Stumble] = []
        var cuts: [SilenceCut] = []
        if info.hasAudio {
            let levels = try await AudioAnalyzer.analyze(clip.url)
            overview = levels
            if style.cutsStumbles, let transcript = clip.transcript { stumbles = StumbleFinder.stumbles(in: transcript.words) }
            cuts = CutPlanner.cuts(levels: levels, timeline: clip.timeline, fps: info.fps, rule: style.pauses, stumbles: stumbles)
        }
        var settings = committedProject.settings
        settings.captions = options.captions
        if options.normaliseAudio, info.hasAudio { settings.audio = .normalised }
        else if settings.audio == .normalised { settings.audio = .aac }
        return AutoEditPlan(clip: clipID, style: style, timeline: clip.timeline, overview: overview, stumbles: stumbles,
                            cuts: cuts, settings: settings, hasTranscript: clip.transcript != nil)
    }

    /// The plan's included cuts, captions and loudness as one undo step. Refused when the
    /// recording's sections changed after it was planned, or when it would leave a section
    /// shorter than a frame.
    @discardableResult
    func applyAutoEdit(_ plan: AutoEditPlan, cutting: Bool = true, origin: EditOrigin = .human,
                       label: String = "Auto Edit") -> Result<EditReceipt, EditError> {
        guard let clip = project.clips.first(where: { $0.id == plan.clip }), let info = clip.info else {
            return .failure(EditError(code: .notFound, message: "That recording is no longer in the project."))
        }
        var commands: [EditCommand] = []
        if cutting, !plan.includedCuts.isEmpty {
            guard clip.timeline == plan.timeline else {
                return .failure(EditError(code: .revisionConflict, message:
                    "The recording's sections changed while the auto edit was working. Run it again."))
            }
            let sections = plan.sections
            guard !sections.isEmpty else { return .failure(.invalid("Keep at least one section of the recording.")) }
            guard sections.allSatisfy({ $0.duration >= 1 / info.fps - 0.000001 }) else {
                return .failure(.invalid("These cuts leave a section shorter than one frame. Uncheck a cut and try again."))
            }
            commands.append(.replaceSections(clip: plan.clip, sections: sections))
        }
        var settings = project.settings
        settings.captions = plan.settings.captions
        settings.audio = plan.settings.audio
        if settings != project.settings { commands.append(.setExportSettings(settings)) }
        guard !commands.isEmpty else {
            return .success(EditReceipt(revision: revision, transactionID: nil, changed: false, createdIDs: [], removedZooms: [],
                                        removedEffects: [], removedMarkers: [], removedGraphics: [], affectedClips: []))
        }
        return perform(commands, label: label, origin: origin)
    }

    // MARK: The owner's Auto Edit

    /// Transcribes the selected recording when its style or captions need the words, finds
    /// the cuts, and applies everything as one undo step, or hands the cuts to the review
    /// list when the style is Review each cut.
    func runAutoEdit() {
        guard autoEditRun == nil, let item = selectedItem, item.info != nil, !isConverting else { return }
        let options = autoEditOptions
        let clip = ProjectClip(item)
        autoEditMessage = nil; autoEditError = nil
        autoEditRun = AutoEditRun(clip: item.id, step: "Starting…")
        autoEditTask = Task { [weak self] in
            guard let self else { return }
            defer { self.autoEditRun = nil; self.autoEditTask = nil }
            do {
                if self.needsTranscript(clip, options: options), clip.transcript == nil {
                    switch Whisper.status(options.model) {
                    case .needsWhisper: throw FFmpegError(message: Whisper.missingMessage)
                    case .needsModel(let model): throw FFmpegError(message: "Download the \(model.label) model first (\(model.sizeLabel)), or choose another model.")
                    case .ready: break
                    }
                    self.autoEditRun = AutoEditRun(clip: item.id, step: "Transcribing with \(options.model.label)…", fraction: 0)
                    try await self.transcribe(item.id, model: options.model, language: options.language, origin: .human) { fraction in
                        Task { @MainActor [weak self] in
                            if self?.autoEditRun?.clip == item.id { self?.autoEditRun?.fraction = fraction }
                        }
                    }
                }
                self.autoEditRun = AutoEditRun(clip: item.id, step: "Finding pauses\(options.cutStyle.cutsStumbles ? " and stumbles" : "")…")
                let plan = try await self.planAutoEdit(item.id, options: options)
                try Task.checkCancellation()
                if plan.style == .review {
                    self.autoEditReview = plan
                    return
                }
                switch self.applyAutoEdit(plan) {
                case .success: self.autoEditMessage = plan.summary + " " + self.autoEditSettingsSummary(plan.settings)
                case .failure(let error): self.autoEditError = error.message
                }
            } catch is CancellationError {
                self.autoEditMessage = "Stopped."
            } catch {
                self.autoEditError = (error as? EditError)?.message ?? error.localizedDescription
            }
        }
    }

    func cancelAutoEdit() { autoEditTask?.cancel() }

    /// "Captions: SRT for upload. Loudness: -14 LUFS."
    func autoEditSettingsSummary(_ settings: ExportSettings) -> String {
        "Captions: \((settings.captions ?? .off).label). " + (settings.audio == .normalised ? "Loudness: \(Loudness.summary)." : "Loudness unchanged.")
    }

    /// The review list's Apply: the cuts the owner kept, with the plan's captions and loudness.
    func applyReviewedAutoEdit(_ plan: AutoEditPlan) -> String? {
        switch applyAutoEdit(plan) {
        case .success:
            autoEditReview = nil
            autoEditMessage = plan.summary + " " + autoEditSettingsSummary(plan.settings)
            return nil
        case .failure(let error): return error.message
        }
    }

    // MARK: Models

    /// Downloads a whisper model. Only ever started by the owner's click.
    func downloadModel(_ model: TranscriptModel) {
        guard modelDownload == nil else { return }
        modelDownloadError = nil
        modelDownload = (model, 0)
        modelDownloadTask = Task {
            do {
                try await Whisper.download(model) { fraction in
                    Task { @MainActor [weak self] in if self?.modelDownload?.model == model { self?.modelDownload = (model, fraction) } }
                }
                statusMessage = "The \(model.label) model is ready: recordings can be transcribed on this Mac."
            } catch is CancellationError {
            } catch {
                modelDownloadError = error.localizedDescription
            }
            modelDownload = nil
            modelDownloadTask = nil
        }
    }

    func cancelModelDownload() { modelDownloadTask?.cancel() }

    /// Forgets the selected recording's transcript (one undo step).
    func removeTranscript() {
        guard let item = selectedItem, item.transcript != nil else { return }
        if case .failure(let error) = perform([.setTranscript(clip: item.id, transcript: nil)]) { statusMessage = error.message }
    }

    /// Transcribes the selected recording on its own, without cutting anything.
    func transcribeSelected() {
        guard autoEditRun == nil, let item = selectedItem, item.info != nil else { return }
        let options = autoEditOptions
        autoEditMessage = nil; autoEditError = nil
        autoEditRun = AutoEditRun(clip: item.id, step: "Transcribing with \(options.model.label)…", fraction: 0)
        autoEditTask = Task { [weak self] in
            guard let self else { return }
            defer { self.autoEditRun = nil; self.autoEditTask = nil }
            do {
                let (transcript, _) = try await self.transcribe(item.id, model: options.model, language: options.language, origin: .human) { fraction in
                    Task { @MainActor [weak self] in if self?.autoEditRun?.clip == item.id { self?.autoEditRun?.fraction = fraction } }
                }
                self.autoEditMessage = "Transcribed \(transcript.words.count) words."
            } catch is CancellationError {
                self.autoEditMessage = "Stopped."
            } catch {
                self.autoEditError = (error as? EditError)?.message ?? error.localizedDescription
            }
        }
    }
}
