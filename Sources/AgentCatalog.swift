import Foundation

/// Everything an agent can ask the app to do, described for an agent to read: each edit
/// command's fields with type, unit, range and default, a worked example, and the rules
/// every request follows. Served by the `catalog` method, so an agent learns the app
/// from the app rather than from prose that may be out of date; `./test.sh` keeps it in
/// step with the commands `apply` actually accepts.
struct AgentCatalog: Encodable {
    struct Field: Encodable {
        var name: String
        var type: String
        var required: Bool
        var description: String
        var unit: String?
        var range: [Double]?
        var defaultValue: JSONValue?
        var values: [String]?

        enum CodingKeys: String, CodingKey { case name, type, required, description, unit, range, defaultValue = "default", values }
    }

    struct Command: Encodable {
        var type: String
        var group: String
        var summary: String
        var fields: [Field]
        var example: JSONValue
    }

    struct Method: Encodable {
        var method: String
        var summary: String
        var fields: [Field]
    }

    var protocolVersion = AgentProtocol.version
    var conventions: [String]
    var workflow: [String]
    var commands: [Command]
    /// Commands for `libraryApply`: the owner's ideas, apart from any project.
    var libraryCommands: [Command]
    var methods: [Method]
}

extension AgentCatalog {
    static let current: AgentCatalog = {
        func field(_ name: String, _ type: String, _ description: String, required: Bool = true, unit: String? = nil,
                   range: ClosedRange<Double>? = nil, default value: JSONValue? = nil, values: [String]? = nil) -> Field {
            Field(name: name, type: type, required: required, description: description, unit: unit,
                  range: range.map { [$0.lowerBound, $0.upperBound] }, defaultValue: value, values: values)
        }
        /// Examples are written with readable placeholders and served with well-formed
        /// made-up ids, so a copied example is at least a valid command.
        func example(_ json: String) -> JSONValue {
            let ids = ["OTHER-CLIP-ID": "0", "SECOND-CLIP-ID": "2", "FIRST-CLIP-ID": "1", "CLIP-ID": "1", "SECTION-ID": "5",
                       "AREA-ID": "a", "ZOOM-ID": "b", "EFFECT-ID": "e", "MARKER-ID": "f", "GRAPHIC-ID": "c", "SHORT-ID": "d", "LAYOUT-ID": "9"]
            var text = json
            for (placeholder, digit) in ids.sorted(by: { $0.key.count > $1.key.count }) {
                text = text.replacingOccurrences(of: placeholder, with: "00000000-0000-4000-8000-00000000000\(digit)")
            }
            return (try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))) ?? .null
        }
        let clip = field("clipID", "uuid", "A recording's id from state.clips[].id.")
        let section = field("sectionID", "uuid", "A section's id from state.clips[].sections[].id.")
        let rect = "rect {x, y, width, height}"
        let timeSpace = field("timeSpace", "string", "\"movie\" to give a movie time instead; the recording is then found from it and clipID may be left out.",
                              required: false, default: .string("recording"), values: ["recording", "movie"])
        let editedSeconds = "seconds of the edited recording"
        var commands: [Command] = []
        func add(_ type: String, _ group: String, _ summary: String, _ fields: [Field], _ json: String) {
            commands.append(Command(type: type, group: group, summary: summary, fields: fields, example: example(json)))
        }

        // Sections
        add("splitSection", "sections", "Cut the section under a time into two. The left half keeps its id; the right half's id is in createdIDs.",
            [clip, field("at", "number", "Where to cut.", unit: editedSeconds), timeSpace],
            #"{"type": "splitSection", "clipID": "CLIP-ID", "at": 4.5}"#)
        add("trimSection", "sections", "Move a section's in or out point. Snaps to source frames; stops being valid if it would overlap a neighbouring section's footage.",
            [clip, section, field("start", "number", "New in point.", required: false, unit: "seconds of the source file"),
             field("end", "number", "New out point.", required: false, unit: "seconds of the source file")],
            #"{"type": "trimSection", "clipID": "CLIP-ID", "sectionID": "SECTION-ID", "start": 1.2}"#)
        add("deleteSection", "sections", "Remove a section; the gap closes. At least one section must remain.", [clip, section],
            #"{"type": "deleteSection", "clipID": "CLIP-ID", "sectionID": "SECTION-ID"}"#)
        add("moveSection", "sections", "Move a section to another position in the recording.",
            [clip, section, field("index", "integer", "The position it should end up at, from 0.")],
            #"{"type": "moveSection", "clipID": "CLIP-ID", "sectionID": "SECTION-ID", "index": 0}"#)
        add("setSectionSpeed", "sections", "Play a section faster or slower. Audio keeps its pitch.",
            [clip, section, field("speed", "number", "Playback rate.", unit: "× normal", range: 0.25...4)],
            #"{"type": "setSectionSpeed", "clipID": "CLIP-ID", "sectionID": "SECTION-ID", "speed": 1.5}"#)
        add("replaceSections", "sections", "Replace every section at once, in play order — how silence removal applies its cuts.",
            [clip, field("sections", "array", "[{id?, start, end, speed?}] in play order; start and end in seconds of the source file.")],
            #"{"type": "replaceSections", "clipID": "CLIP-ID", "sections": [{"start": 0, "end": 3.2}, {"start": 4.1, "end": 9, "speed": 1.25}]}"#)

        // Frame
        add("setCrop", "frame", "Crop the recording. Snaps to even pixels.",
            [clip, field("rect", rect, "The area to keep, at least 16×16.", unit: "source pixels, origin top-left")],
            #"{"type": "setCrop", "clipID": "CLIP-ID", "rect": {"x": 0, "y": 140, "width": 1920, "height": 800}}"#)
        add("setAspect", "frame", "Lock future crop drags to a shape. Does not move the crop by itself.",
            [clip, field("preset", "string", "The shape.", values: AspectPreset.all.map(\.label))],
            #"{"type": "setAspect", "clipID": "CLIP-ID", "preset": "9:16"}"#)

        // Blur areas
        let area = field("areaID", "uuid", "A blur area's id from state.clips[].blurAreas[].id.")
        add("addBlurArea", "blur areas", "Hide part of the picture for the whole recording (a face, a name). Style and strength are export settings.",
            [clip, field("rect", rect, "The area to hide.", unit: "source pixels, origin top-left"),
             field("areaID", "uuid", "Choose the new area's id, to refer to it later in the same request.", required: false)],
            #"{"type": "addBlurArea", "clipID": "CLIP-ID", "rect": {"x": 40, "y": 40, "width": 320, "height": 120}}"#)
        add("updateBlurArea", "blur areas", "Move or resize a blur area.", [clip, area, field("rect", rect, "Its new place.", unit: "source pixels")],
            #"{"type": "updateBlurArea", "clipID": "CLIP-ID", "areaID": "AREA-ID", "rect": {"x": 60, "y": 40, "width": 320, "height": 120}}"#)
        add("removeBlurArea", "blur areas", "Remove a blur area.", [clip, area],
            #"{"type": "removeBlurArea", "clipID": "CLIP-ID", "areaID": "AREA-ID"}"#)
        add("replaceBlurAreas", "blur areas", "Replace every blur area at once.",
            [clip, field("areas", "array", "[{id?, rect}] in source pixels.")],
            #"{"type": "replaceBlurAreas", "clipID": "CLIP-ID", "areas": []}"#)

        // Zooms
        let zoom = field("zoomID", "uuid", "A zoom's id from state.clips[].zooms[].id.")
        add("addZoom", "zooms", "Push in on a point: half a second easing in, a hold, half a second easing out. Zooms may not overlap.",
            [clip, field("start", "number", "When the ease-in begins.", unit: editedSeconds),
             field("target", "point {x, y}", "What to zoom towards.", unit: "source pixels, origin top-left"),
             field("hold", "number", "How long it holds at full zoom, at least 0.2.", required: false, unit: "seconds", default: .number(2)),
             field("level", "number", "Magnification at the peak.", required: false, unit: "×", range: 1...10, default: .number(2)),
             field("zoomID", "uuid", "Choose the new zoom's id.", required: false), timeSpace],
            #"{"type": "addZoom", "clipID": "CLIP-ID", "start": 3, "target": {"x": 960, "y": 540}, "level": 1.5}"#)
        add("updateZoom", "zooms", "Change any of a zoom's start, hold, level or target; the rest stay.",
            [clip, zoom, field("start", "number", "New start.", required: false, unit: editedSeconds),
             field("hold", "number", "New hold, at least 0.2.", required: false, unit: "seconds"),
             field("level", "number", "New level.", required: false, unit: "×", range: 1...10),
             field("target", "point {x, y}", "New target.", required: false, unit: "source pixels")],
            #"{"type": "updateZoom", "clipID": "CLIP-ID", "zoomID": "ZOOM-ID", "hold": 3}"#)
        add("removeZoom", "zooms", "Remove a zoom.", [clip, zoom], #"{"type": "removeZoom", "clipID": "CLIP-ID", "zoomID": "ZOOM-ID"}"#)
        add("replaceZooms", "zooms", "Replace every zoom at once.",
            [clip, field("zooms", "array", "[{id?, start, target, hold?, level?}].")],
            #"{"type": "replaceZooms", "clipID": "CLIP-ID", "zooms": []}"#)

        // Whole-frame blur effects
        let effect = field("effectID", "uuid", "An effect's id from state.clips[].blurEffects[].id.")
        let effectFields = [
            field("amount", "number", "Blur strength: the Gaussian standard deviation on a picture 1080 pixels on its long side, scaled to the real frame.",
                  required: false, range: VideoBlurEffect.amountRange, default: .number(VideoBlurEffect.defaultAmount)),
            field("mix", "number", "Share of the blurred picture at full strength: 0 none, 1 all of it.", required: false,
                  range: VideoBlurEffect.mixRange, default: .number(1)),
            field("fadeIn", "number", "Ease in from no blur. fadeIn + fadeOut must fit in the duration.", required: false, unit: "seconds",
                  default: .number(VideoBlurEffect.defaultFade)),
            field("fadeOut", "number", "Ease back out.", required: false, unit: "seconds", default: .number(VideoBlurEffect.defaultFade)),
            field("enabled", "boolean", "false keeps the block and its place but draws nothing.", required: false, default: .bool(true)),
        ]
        add("addBlurEffect", "effects", "Blur the whole visible picture for a while, fading in and out — a transition, a private moment, a backdrop for a title. Runs [start, end); effects on one recording may touch but not overlap. Times snap to frames. Default fades shrink to fit a short effect.",
            [clip, field("start", "number", "When it begins.", unit: editedSeconds),
             field("end", "number", "When it ends (exclusive). Give end or duration.", required: false, unit: editedSeconds),
             field("duration", "number", "Instead of end.", required: false, unit: "seconds", default: .number(VideoBlurEffect.defaultDuration))]
            + effectFields + [field("effectID", "uuid", "Choose the new effect's id.", required: false), timeSpace],
            #"{"type": "addBlurEffect", "clipID": "CLIP-ID", "start": 2, "duration": 3, "amount": 30, "fadeIn": 0.5, "fadeOut": 0.5}"#)
        add("updateBlurEffect", "effects", "Change any of an effect's timing or settings; the rest stay. Moving start keeps the duration.",
            [clip, effect, field("start", "number", "New start; the end moves with it.", required: false, unit: editedSeconds),
             field("end", "number", "New end.", required: false, unit: editedSeconds),
             field("duration", "number", "New length from the start.", required: false, unit: "seconds")] + effectFields,
            #"{"type": "updateBlurEffect", "clipID": "CLIP-ID", "effectID": "EFFECT-ID", "mix": 0.6, "enabled": true}"#)
        add("removeBlurEffect", "effects", "Remove an effect.", [clip, effect],
            #"{"type": "removeBlurEffect", "clipID": "CLIP-ID", "effectID": "EFFECT-ID"}"#)

        // Markers
        let marker = field("markerID", "uuid", "A marker's id from state.clips[].markers[].id.")
        let colors = TimelineMarker.Color.allCases.map(\.rawValue)
        add("addMarker", "markers", "Name a moment on the timeline — a note to the owner, or a place to come back to. Markers follow their frame through cuts.",
            [clip, field("time", "number", "Where.", unit: editedSeconds),
             field("label", "string", "A short name, one line.", required: false, default: .string("")),
             field("color", "string", "Flag colour.", required: false, default: .string("blue"), values: colors),
             field("markerID", "uuid", "Choose the new marker's id.", required: false), timeSpace],
            #"{"type": "addMarker", "clipID": "CLIP-ID", "time": 12.4, "label": "Best take", "color": "green"}"#)
        add("updateMarker", "markers", "Move, rename or recolour a marker.",
            [clip, marker, field("time", "number", "New place.", required: false, unit: editedSeconds),
             field("label", "string", "New name.", required: false), field("color", "string", "New colour.", required: false, values: colors)],
            #"{"type": "updateMarker", "clipID": "CLIP-ID", "markerID": "MARKER-ID", "label": "Check the audio here"}"#)
        add("removeMarker", "markers", "Remove a marker.", [clip, marker],
            #"{"type": "removeMarker", "clipID": "CLIP-ID", "markerID": "MARKER-ID"}"#)

        // Graphics
        let graphicID = field("graphicID", "uuid", "A graphic's id from state.clips[].graphics.items[].id.")
        let kinds = GraphicKind.allCases.map(\.rawValue)
        let graphicObject = field("graphic", "object",
            "{kind, start, end, props, look?, transform?, id?}. kind is one of the values; namePlate, featureList, titleCard, phoneScreens, route, link and endCard sit in the right-hand column, panelTitle, rule and checklist in the side panel, and endScreen takes the whole screen for YouTube's end screen: the speaker moves into a half-size frame and empty boxes stay clear where YouTube puts its Subscribe circle and video cards (props: videos 1 or 2, side left or right for the speaker, kicker, title; it ends where the video ends, lasts 5–20 s, nothing else may show during it, it cannot be moved on the picture, and start and end may be left out for the last 20 s or as much of them as is clear; state.clips[].endScreen lists its boxes). logoBadge shows brand logos next to the speaker when the brand is said, wherever the layout puts the speaker (beside the face, beside the bubble, at the foot of the side-by-side panel; in a Short beside the face, logos without labels as the captions say the names): props logos, one to three {image, label (30 characters or fewer), at}, and tone light (white chips, the default) or dark; the app works out its place (props.spot), so transform only nudges it; analyze with kind logos suggests them. kineticText and sectionCard cover the whole picture (nothing else may show with them, a panel must have slid away, and they cannot be moved): kineticText shows big words, each on the time it is spoken, props words (1–24 {text, at}, in order, the last at least 0.25 s before it ends; or \"transcript\", and the app fills in the words said over its time) or text (spread evenly), layout line (one centred line, the default) or stack (one word on each line), background solid (near black, the default) or dim (the picture darkened), *words* in the accent; sectionCard shows a section's title (40 characters or fewer) and an optional kicker over a seek bar split at every section card, filled up to where this one starts (the app writes progress and marks), for 1–8 s, background as kineticText; in a Short, captions pause under both. start and end are edited-recording seconds; props is the template's data (see Tools/Graphics/README.md and docs/plans/graphics-track.md section 3): beat times in it (at, …At) are seconds after start, and image values are absolute paths to files that exist. look is glass or ink for this graphic alone. transform {x, y, scale} moves it on the picture: x and y in pixels of a 1920×1080 frame (−1920–1920, −1080–1080) from its place in the template, scale 0.4–2.5 from the top-left corner of its zone; {x: 0, y: 0, scale: 1} puts it back. preview with composed: true draws the graphics and returns each one's box.",
            values: kinds)
        let styleKeys = "Only the keys to change: accent (\"#F5C42C\"), panel (shade|solid), moveVideo (slide the picture aside while a panel shows), edge (soft edge of the shade, 0–400 px, default 170), look (glass|ink|mix; mix writes panel graphics in ink), size (1 to 1.5, or null for 1: draws cards that much larger and panels half as much larger, for viewers on a phone; cards grow left from the column's top-right corner and panels from the panel's top-right corner; logo badges, the end screen and Shorts keep their own sizes; a graphic's own transform applies on top)."
        let styleObject = field("graphicsStyle", "object", styleKeys)
        add("addGraphic", "graphics", "Add a timed motion graphic over the recording. Two graphics in the same place (column, panel or next to the speaker) may not overlap, and a cover (kineticText, sectionCard) may not overlap any other; a graphic shows for at least 0.5 s and ends inside the recording. An endScreen needs only its kind.",
            [clip, graphicObject, timeSpace],
            #"{"type": "addGraphic", "clipID": "CLIP-ID", "graphic": {"kind": "namePlate", "start": 0.3, "end": 4.3, "props": {"title": "Yamparala Rahul", "detail": "UX Design Engineer"}}}"#)
        add("updateGraphic", "graphics", "Change a graphic. Give only the fields to change; moving start keeps the length (an endScreen keeps its end at the video's end instead); props, when given, replaces all props; look \"\" goes back to the style's choice.",
            [clip, graphicID, field("graphic", "object", "{kind?, start?, end?, props?, look?, transform?}; in transform only the keys given change.")],
            #"{"type": "updateGraphic", "clipID": "CLIP-ID", "graphicID": "GRAPHIC-ID", "graphic": {"start": 12.0, "transform": {"y": 120, "scale": 1.2}}}"#)
        add("removeGraphic", "graphics", "Remove a graphic.", [clip, graphicID],
            #"{"type": "removeGraphic", "clipID": "CLIP-ID", "graphicID": "GRAPHIC-ID"}"#)
        add("replaceGraphics", "graphics", "Set every graphic on the recording at once, and the style too when given.",
            [clip, field("graphics", "array", "Graphics as in addGraphic."), field("graphicsStyle", "object", styleKeys, required: false)],
            #"{"type": "replaceGraphics", "clipID": "CLIP-ID", "graphics": [], "graphicsStyle": {"look": "mix"}}"#)
        add("setGraphicsStyle", "graphics", "Change how every graphic on the recording looks.",
            [clip, styleObject],
            #"{"type": "setGraphicsStyle", "clipID": "CLIP-ID", "graphicsStyle": {"panel": "shade", "edge": 170}}"#)
        add("importGraphics", "graphics", "Read a graphics.json file (the format Tools/Graphics uses) onto the recording, replacing its graphics and style. Image paths in the file are relative to it and must exist.",
            [clip, field("path", "string", "A local graphics.json file.")],
            #"{"type": "importGraphics", "clipID": "CLIP-ID", "path": "/Users/me/Desktop/recut/graphics.json"}"#)

        // Colour
        add("setInputProfile", "colour", "Say how the recording's colour was recorded. A profile the conversion does not fit removes it. HLG/PQ only for files tagged so; D-Log M never for a file tagged HDR.",
            [clip, field("profile", "string", "Auto decides only from HDR tags and leaves a DJI file as recorded until told.",
                         values: ColorInputProfile.allCases.map(\.rawValue))],
            #"{"type": "setInputProfile", "clipID": "CLIP-ID", "profile": "pocket3DLogM"}"#)
        add("importTechnicalLUT", "colour", "Read, check and attach DJI's Pocket 3 D-Log M to Rec.709 .cube conversion. Needs profile pocket3DLogM (set it earlier in the same request). state reports whether it is DJI's official file.",
            [clip, field("path", "string", "A local .cube file.")],
            #"{"type": "importTechnicalLUT", "clipID": "CLIP-ID", "path": "~/Downloads/DJI OSMO Pocket 3 D-Log M to Rec.709 V1.cube"}"#)
        add("clearTechnicalLUT", "colour", "Detach the conversion; Natural colour turns off with it.", [clip],
            #"{"type": "clearTechnicalLUT", "clipID": "CLIP-ID"}"#)
        add("setColorCorrection", "colour", "Natural colour: apply the D-Log M conversion, or show the recording as recorded.",
            [clip, field("enabled", "boolean", "true to correct.")],
            #"{"type": "setColorCorrection", "clipID": "CLIP-ID", "enabled": true}"#)
        add("setColorAdjustments", "colour", "Set any of the four beginner controls; the rest stay. Applied in linear light after any conversion.",
            [clip, field("exposureEV", "number", "Brightness.", required: false, unit: "stops", range: ColorAdjustments.exposureRange, default: .number(0)),
             field("warmth", "number", "Cooler below 0, warmer above.", required: false, range: ColorAdjustments.warmthRange, default: .number(0)),
             field("contrast", "number", "About 18% grey.", required: false, unit: "×", range: ColorAdjustments.contrastRange, default: .number(1)),
             field("saturation", "number", "Colour strength.", required: false, unit: "×", range: ColorAdjustments.saturationRange, default: .number(1))],
            #"{"type": "setColorAdjustments", "clipID": "CLIP-ID", "exposureEV": 0.3, "warmth": 0.15}"#)
        add("resetColorAdjustments", "colour", "The four controls back to neutral; the conversion stays.", [clip],
            #"{"type": "resetColorAdjustments", "clipID": "CLIP-ID"}"#)
        add("copyColorAdjustments", "colour", "Copy one recording's look to others in one step.",
            [field("clipID", "uuid", "The recording to copy from."),
             field("targets", "uuid[]", "The recordings to copy to."),
             field("includeInterpretation", "boolean", "Also copy the recorded colour and conversion — only for footage recorded the same way.",
                   required: false, default: .bool(false))],
            #"{"type": "copyColorAdjustments", "clipID": "CLIP-ID", "targets": ["OTHER-CLIP-ID"]}"#)

        // Movie and project
        add("setMovieOrder", "movie", "Order the recordings in the movie.", [field("order", "uuid[]", "Every recording's id, each once.")],
            #"{"type": "setMovieOrder", "order": ["SECOND-CLIP-ID", "FIRST-CLIP-ID"]}"#)
        add("setIncludedInMovie", "movie", "Leave a recording out of the movie, or put it back.",
            [clip, field("included", "boolean", "false to leave it out.")],
            #"{"type": "setIncludedInMovie", "clipID": "CLIP-ID", "included": false}"#)
        add("setMovieCanvas", "movie", "The movie's frame shape.",
            [field("canvas", "string", "firstClip matches the first recording's crop.", values: MovieCanvas.allCases.map(\.rawValue))],
            #"{"type": "setMovieCanvas", "canvas": "portrait"}"#)
        add("setExportSettings", "project", "Change export settings; only the keys given change. graphics: false exports without each recording's graphics and the move aside under its panels. captions: burnIn, upload or off (what exports and Export for YouTube do with captions; null goes back to burning in a caption file only). shortCaptions: the same for Shorts, on their own (null burns them in whenever the video has captions, so a long video can upload an SRT while its Shorts burn them in). audio: normalised exports at -14 LUFS.",
            [field("settings", "object", "Keys to change.", values: AgentCatalog.exportSettingKeys.sorted())],
            #"{"type": "setExportSettings", "settings": {"format": "gif", "frameRate": 12}}"#)
        add("setPublishInfo", "publish", "Set what YouTube gets for a recording; only the keys given change. YouTube's limits (title 100 characters, description 5000 with its chapters, tags 500 as YouTube counts them, chapters from 0:00, at least 3, each 10 s or more) show in state.clips[].publishIssues rather than being refused, so a draft can be written in steps; state.clips[].suggestedChapters has chapters made from named markers and panel, rule, checklist and title graphics. Chapters follow their footage through cuts.",
            [clip, field("publish", "object", "Keys to change: title, description, tags (list of text), category (one of the values), chapters ([{time, title}], edited-recording seconds; replaces the list), thumbnail (path to an image, or null), language (like en), channel (for the owner's preview), design (the thumbnail maker's design; only its keys given change: time (edited seconds of the frame), title (up to 3 lines, *words* in the accent), highlight (true: the *words* in dark text on a band of the accent), tag, accent (#RRGGBB), image (path), imageSize (the image's size, 1–1.6 times its usual size, which is at most 520×340 px of a 1920×1080 frame; the title gets smaller to make room), cutout, outline, outlineWidth (2–16 px of a 1920×1080 frame, default 9), side (auto, left, right), background (frame, dim, blur, solid, white, frost: the frame as recorded, moved with the speaker, under a white blurred shade on the title side that fades out before the speaker; title in dark text), zoom (1–1.6), place (frame: the speaker where the frame has them; clear: moved to the far side and made smaller when necessary, so the title, tag and image do not overlap them; use with background solid, white or frost)), endScreen (which YouTube element goes in each box of the endScreen graphic; only its keys given change: circle (subscribe or channel; channel and message name the other channel), videos (one per video box, top first: [{kind: bestForViewer|recentUpload|video|playlist, link, title}], link a YouTube link for video and playlist)). YouTube's upload API cannot set end screen elements, so Export for YouTube writes where each goes for YouTube Studio.",
                         values: YouTubeCategory.allCases.map(\.rawValue))],
            #"{"type": "setPublishInfo", "clipID": "CLIP-ID", "publish": {"title": "How I edit with YamVideo", "tags": ["video editing", "macOS"], "chapters": [{"time": 0, "title": "Intro"}, {"time": 42, "title": "Cutting"}, {"time": 95, "title": "Graphics"}]}}"#)
        add("setSubtitles", "project", "Give a recording a caption file. It is used before the transcript's captions; settings.captions decides whether exports burn it in (burnIn), only upload it with Export for YouTube (upload) or leave it out (off). Without settings.captions a file is burned in.",
            [clip, field("path", "string", "A local .srt, .vtt or .ass file.")],
            #"{"type": "setSubtitles", "clipID": "CLIP-ID", "path": "~/Movies/talk.srt"}"#)
        add("clearSubtitles", "project", "Remove a recording's caption file; captions then come from its transcript, if settings.captions is on.", [clip],
            #"{"type": "clearSubtitles", "clipID": "CLIP-ID"}"#)

        // Auto edit
        add("setProjectNotes", "project", "Replace the project's Why notes (Markdown): why the video is edited the way it is. Video.md shows them. \"\" clears them.",
            [field("notes", "string", "All of the notes, up to \(ChangeLogEntry.notesLimit) characters.")],
            #"{"type": "setProjectNotes", "notes": "- Kept the Nokia story whole: it is why the app exists."}"#)
        add("addProjectNote", "project", "Add one line to the project's Why notes, signed with your name and the date: a decision and its reason, or the owner's feedback. Use it after each choice of taste the owner approves.",
            [field("note", "string", "One line, up to 1000 characters.")],
            #"{"type": "addProjectNote", "note": "Zoomed the Shorts out to 3:4 because the captions covered the face."}"#)
        add("setAutoEditOptions", "auto edit", "Change the project's auto edit answers; only the keys given change. state.autoEdit shows them. autoEdit (the method) and the owner's Auto Edit button follow them.",
            [field("autoEdit", "object", "Keys to change: model (whisper model: " + TranscriptModel.allCases.map(\.rawValue).joined(separator: " or ")
                   + "; base.en is English only), language (a whisper language code such as en, hi, te, or auto), cutStyle (tight: pauses of 0.42 s or more become about 0.22 s, 0.30 s after a comma and 0.40 s after a sentence when the transcript says where they end, and stumbles from the transcript go; natural: pauses of 0.8 s or more become 0.3 s; review: the tight cuts, chosen by the owner), captions (upload: an SRT goes up with Export for YouTube; burnIn: also drawn into the picture; off), normaliseAudio (true: exports at -14 LUFS).",
                   values: ["model", "language", "cutStyle", "captions", "normaliseAudio"])],
            #"{"type": "setAutoEditOptions", "autoEdit": {"cutStyle": "natural", "captions": "burnIn"}}"#)
        add("importTranscript", "auto edit", "Set a recording's transcript from a file: whisper-cli's full JSON (-ojf, with -dtw for word times) or {model, language, words: [{text, start, end}]} in source seconds. Replaces any transcript; one undo step.",
            [clip, field("path", "string", "A local JSON file.")],
            #"{"type": "importTranscript", "clipID": "CLIP-ID", "path": "~/Movies/talk.json"}"#)
        add("clearTranscript", "auto edit", "Forget a recording's transcript (and the captions made from it).", [clip],
            #"{"type": "clearTranscript", "clipID": "CLIP-ID"}"#)
        // Shorts
        let shortID = field("shortID", "uuid", "A Short's id from state.clips[].shorts[].id.")
        let shortKeys = "Keys to set (only those given change): start and end (edited-recording seconds; a Short lasts 1 s to 3:00 and Shorts of one recording do not overlap; moving start alone keeps the length), window ({x, y, width, height} in source pixels, 9:16 and inside the picture; \"speaker\" centres it on the face Apple Vision finds; \"centre\" or null is the full height, centred), title, description, tags (list of text; the Short's own upload details), hidden (graphic ids left out of this Short), placements ({graphicID: {x, y, scale}} on the Short's 1080×1920 canvas, null puts one back), cover (seconds into the Short of the cover frame, or null), panels (sheet: a frosted shade rises over the lower half and the picture lifts by an eighth with moveVideo on; shade: the whole picture frosts and dims with the panel large in the middle; split: the picture shrinks into a frame in the top half with the panel below), captions (what burned-in captions do while a card or panel covers the lower half: stepUp moves them above it, over keeps them over it, hide pauses them), zoom (1 or null fills the frame; down to 0.5625 zooms out: the window widens to show more of the picture, which sits at the top of the Short with its bottom fading into a blurred copy, and cards, the bottom sheet and the captions sit lower, under the face; 0.75 is a gentle 3:4, 0.5625 a square), screen (for a recording with a screen recording: off shows only the speaker; top puts the screen across the top and the speaker below, on the 1080×1920 canvas, where the recording's layout shows the screen, and the speaker alone where it shows only the speaker; the captions sit between the two; a Short with the screen does not zoom out)."
        add("addShort", "shorts", "Add a Short: a vertical 1080×1920 version of part of the recording for YouTube Shorts, with the same edit, graphics (laid out for 9:16; the end screen is left out, as Shorts have none) and captions (in the safe area, sized for a phone). With no times it covers the whole recording when that is under 3:00, else the minute from the start (or from start). Its id is in createdIDs. state.clips[].shorts shows it with its issues; preview with short draws it.",
            [clip, field("short", "object", shortKeys + " Also id, to choose the new Short's id.", required: false), field("shortID", "uuid", "The new Short's id, when you choose it.", required: false)],
            #"{"type": "addShort", "clipID": "CLIP-ID", "short": {"start": 42.0, "end": 98.5, "window": "speaker", "title": "Why I edit on a Mac", "panels": "sheet", "captions": "stepUp"}}"#)
        add("updateShort", "shorts", "Change a Short. Give only the keys to change.",
            [clip, shortID, field("short", "object", shortKeys)],
            #"{"type": "updateShort", "clipID": "CLIP-ID", "shortID": "SHORT-ID", "short": {"panels": "shade", "captions": "hide", "placements": {"GRAPHIC-ID": {"y": -120, "scale": 1.1}}}}"#)
        add("removeShort", "shorts", "Remove a Short.", [clip, shortID],
            #"{"type": "removeShort", "clipID": "CLIP-ID", "shortID": "SHORT-ID"}"#)

        // Screen + speaker
        let layoutID = field("layoutID", "uuid", "A layout's id from state.clips[].screen.layouts[].id.")
        let layoutKinds = "speaker (the speaker fills the frame), screen (the screen fills the frame, the speaker in a bubble in a corner, a circle or a square with soft corners), split (the speaker in a tall panel on the left, the screen on the right) or ink (the speaker on the right at full size; on the left, over a dark shade, only the screen's bright lines, its dark background keyed out: for hand-drawn ink from a drawing app on a dark canvas; the screen's crop picks the part where the lines are, and screen zooms make small writing larger; in a Short it shows as screen does)"
        let layoutKeys = "{start, end, layout}: start and end in edited-recording seconds, half-open; layouts on one recording may touch but not overlap. layout is \(layoutKinds). A change of layout eases over 0.4 s from its start."
        add("setScreen", "screen", "Show a screen recording with this recording (the speaker). The speaker stays the master: its audio, sections and edits drive both pictures, and every cut cuts the screen at the same moment. A first screen starts in the screen layout with the bubble on the face Apple Vision finds. Replacing the file keeps the layouts. state.clips[].screen shows it, with covered: the edited times where the screen file has footage (outside them its first or last frame holds).",
            [clip, field("path", "string", "A local video file: the screen recording. It is probed first; it may not be rotated or HDR."),
             field("offset", "number", "The screen recording's time at this recording's source time 0: screen time = source time + offset. Find it from a moment you can see in both, such as a click the speaker names. Default 0, or the current offset when replacing.", required: false, unit: "seconds")],
            #"{"type": "setScreen", "clipID": "CLIP-ID", "path": "~/Movies/Screen Recording.mov", "offset": 142.5}"#)
        add("updateScreen", "screen", "Change the screen: give only the keys to change.",
            [clip, field("screen", "object", "Keys: offset (seconds), crop ({x, y, width, height} in the screen recording's pixels, \"border\" to cut away a dark border round a recorded window, or null for all of it), layout (the base layout, used wherever no layout span says otherwise: \(layoutKinds)), bubble ({corner: topLeft, topRight, bottomLeft or bottomRight; size: 0.15 to 0.5, the bubble's side as a share of the frame's height; face: {x, y} in this recording's source pixels, \"speaker\" to find it with Apple Vision, or null for the middle; shape: circle, or rounded for a square with soft corners; corners: 0.05 to 0.45, a rounded square's corner radius as a share of its side, default 0.2}).")],
            #"{"type": "updateScreen", "clipID": "CLIP-ID", "screen": {"offset": 142.6, "crop": {"x": 0, "y": 88, "width": 3248, "height": 1920}, "bubble": {"corner": "bottomRight", "size": 0.3, "face": "speaker", "shape": "rounded", "corners": 0.2}}}"#)
        add("removeScreen", "screen", "Remove the screen recording and its layouts.", [clip],
            #"{"type": "removeScreen", "clipID": "CLIP-ID"}"#)
        add("addLayout", "screen", "Give part of the recording a layout of its own. Its id is in createdIDs. Layouts follow the footage they start on through cuts.",
            [clip, field("layout", "object", layoutKeys + " Also id, to choose the new layout's id."),
             field("layoutID", "uuid", "The new layout's id, when you choose it.", required: false)],
            #"{"type": "addLayout", "clipID": "CLIP-ID", "layout": {"start": 0, "end": 28.5, "layout": "speaker"}}"#)
        add("updateLayout", "screen", "Change a layout. Give only the keys to change; moving start alone keeps the length.",
            [clip, layoutID, field("layout", "object", layoutKeys)],
            #"{"type": "updateLayout", "clipID": "CLIP-ID", "layoutID": "LAYOUT-ID", "layout": {"layout": "split"}}"#)
        add("removeLayout", "screen", "Remove a layout; the base layout shows there again.", [clip, layoutID],
            #"{"type": "removeLayout", "clipID": "CLIP-ID", "layoutID": "LAYOUT-ID"}"#)
        let zoomFields = "start (edited-recording seconds, when the ease in begins), hold (seconds at full zoom, default 2, at least 0.2), level (1 to 10, default 2) and target ({x, y} in the screen recording's pixels, as state.clips[].screen.media sizes it)"
        add("addScreenZoom", "screen", "A push-in on the screen, to make small text readable: it eases in over 0.5 s, holds, and eases out. The screen's stream keeps up to the recording's own detail for it. Its id is in createdIDs. Screen zooms follow their footage through cuts; analyze with kind screenZooms suggests some.",
            [clip, field("start", "number", "When the ease in begins.", unit: editedSeconds),
             field("target", "point", "Where to zoom, in the screen recording's pixels."),
             field("hold", "number", "Seconds at full zoom.", required: false, unit: "seconds", range: 0.2...30, default: .number(2)),
             field("level", "number", "Magnification.", required: false, range: 1...10, default: .number(2)),
             field("zoomID", "uuid", "The new zoom's id, when you choose it.", required: false)],
            #"{"type": "addScreenZoom", "clipID": "CLIP-ID", "start": 48.0, "hold": 3, "level": 2, "target": {"x": 1700, "y": 160}}"#)
        add("updateScreenZoom", "screen", "Change a screen zoom; only the fields given change.",
            [clip, field("zoomID", "uuid", "A screen zoom's id from state.clips[].screen.zooms[].id."),
             field("start", "number", "When the ease in begins.", required: false, unit: editedSeconds),
             field("hold", "number", "Seconds at full zoom.", required: false, unit: "seconds"),
             field("level", "number", "Magnification.", required: false, range: 1...10),
             field("target", "point", "Where to zoom, in the screen recording's pixels.", required: false)],
            #"{"type": "updateScreenZoom", "clipID": "CLIP-ID", "zoomID": "ZOOM-ID", "level": 3}"#)
        add("removeScreenZoom", "screen", "Remove a screen zoom.", [clip, field("zoomID", "uuid", "A screen zoom's id.")],
            #"{"type": "removeScreenZoom", "clipID": "CLIP-ID", "zoomID": "ZOOM-ID"}"#)
        // Changes
        add("setChange", "changes", "Switch a change off or on, as the inspector's switch does. Off keeps it in the project but leaves it out of the player and every export; on brings it back. state.clips[].switchedOff lists what is off.",
            [clip, field("change", "string", "The change.", values: SwitchableChange.allCases.map(\.rawValue)),
             field("on", "boolean", "true brings it back; false switches it off.")],
            #"{"type": "setChange", "clipID": "CLIP-ID", "change": "zooms", "on": false}"#)
        add("replaceScreenZooms", "screen", "Every screen zoom at once.",
            [clip, field("zooms", "array", "The zooms, each with " + zoomFields + "; they may not overlap.")],
            #"{"type": "replaceScreenZooms", "clipID": "CLIP-ID", "zooms": [{"start": 48.0, "hold": 3, "level": 2, "target": {"x": 1700, "y": 160}}]}"#)
        add("replaceLayouts", "screen", "Every layout at once, as a plan from the transcript gives them: for example speaker for the intro and the outro, split where the speaker explains, and the base screen layout elsewhere.",
            [clip, field("layouts", "array", "The layouts, each " + layoutKeys)],
            #"{"type": "replaceLayouts", "clipID": "CLIP-ID", "layouts": [{"start": 0, "end": 30.2, "layout": "speaker"}, {"start": 512, "end": 531, "layout": "speaker"}]}"#)

        add("addMedia", "project", "Add recordings; each is probed first. New ids are in createdIDs.",
            [field("paths", "string[]", "Local video files.")], #"{"type": "addMedia", "paths": ["~/Movies/take2.mov"]}"#)
        add("removeMedia", "project", "Remove a recording from the project (the file is untouched).", [clip],
            #"{"type": "removeMedia", "clipID": "CLIP-ID"}"#)
        add("relinkMedia", "project", "Point a recording at a moved copy of the same video, keeping every edit.",
            [clip, field("path", "string", "The moved file; same size and length.")],
            #"{"type": "relinkMedia", "clipID": "CLIP-ID", "path": "~/Movies/moved.mov"}"#)

        // The Library: ideas, apart from any project (method libraryApply).
        var libraryCommands: [Command] = []
        func library(_ type: String, _ summary: String, _ fields: [Field], _ json: String) {
            libraryCommands.append(Command(type: type, group: "ideas", summary: summary, fields: fields,
                                           example: example(json.replacingOccurrences(of: "IDEA-ID", with: "00000000-0000-4000-8000-000000000001"))))
        }
        let idea = field("ideaID", "uuid", "An idea's id from library.ideas[].id.")
        library("addIdea", "Add an idea at the top of the Library list. Use the owner's own words; ask when unsure. Its id is in createdIDs, or choose it with ideaID to refer to it in the same request.",
                [field("title", "string", "One line, up to \(ContentItem.titleLimit) characters."),
                 field("ideaID", "uuid", "Your choice of id for the new idea.", required: false),
                 field("notes", "string", "Free text, up to \(ContentItem.notesLimit) characters: the hook, the points, why it matters.", required: false, default: .string("")),
                 field("topic", "string", "What it is about, up to \(ContentItem.topicLimit) characters. Reuse one of library.topics where it fits; a topic differing only in case takes the existing spelling.", required: false),
                 field("links", "string[]", "Web links (http or https; a bare address gets https://), up to \(ContentItem.linkCount).", required: false),
                 field("paths", "string[]", "Local image files (PNG, JPEG, HEIC, GIF, WebP, TIFF, BMP; 25 MB each) to copy into the Library.", required: false)],
                #"{"type": "addIdea", "title": "How I edit with Claude", "topic": "AI workflow", "notes": "Hook: one recording, Claude cuts it while I watch.", "links": ["https://example.com/reference"]}"#)
        library("updateIdea", "Change an idea's title, notes, topic or links. Only the fields sent change; links replaces the whole list.",
                [idea, field("title", "string", "One line.", required: false), field("notes", "string", "Replaces the notes.", required: false),
                 field("topic", "string", "\"\" clears it.", required: false), field("links", "string[]", "The whole new list.", required: false)],
                #"{"type": "updateIdea", "ideaID": "IDEA-ID", "topic": "AI workflow"}"#)
        library("removeIdea", "Delete an idea. Ask the owner first. Its linked project file is untouched; undo brings the idea back.", [idea],
                #"{"type": "removeIdea", "ideaID": "IDEA-ID"}"#)
        library("addIdeaImages", "Copy images into the Library and add them to an idea, up to \(ContentItem.imageCount) per idea.",
                [idea, field("paths", "string[]", "Local image files.")],
                #"{"type": "addIdeaImages", "ideaID": "IDEA-ID", "paths": ["~/Desktop/reference.png"]}"#)
        library("removeIdeaImage", "Take an image off an idea.", [idea, field("image", "string", "Its name from library.ideas[].images[].name.")],
                #"{"type": "removeIdeaImage", "ideaID": "IDEA-ID", "image": "00000000-0000-4000-8000-000000000002.png"}"#)
        library("linkProject", "Link a saved project to an idea, which moves it to In production. A project belongs to one idea at most.",
                [idea, field("path", "string", "A .yamvideo file. Left out: the project open in Studio, which must be saved.", required: false)],
                #"{"type": "linkProject", "ideaID": "IDEA-ID", "path": "~/Movies/How I edit with Claude.yamvideo"}"#)
        library("unlinkProject", "Make it only an idea again. The project file is untouched.", [idea],
                #"{"type": "unlinkProject", "ideaID": "IDEA-ID"}"#)
        library("importVideos", "Add videos the owner already made: each project found becomes an item with its exports (an item that already holds the project gets only the new exports); an export whose project is not found becomes an item of its own. Nothing is copied. Ask the owner first; scanFolder shows what would be added.",
                [field("paths", "string[]", "Folders, .yamvideo projects or .youtube.json exports. Folders are searched inside, skipping hidden folders.")],
                #"{"type": "importVideos", "paths": ["~/Desktop/DJIFootage"]}"#)
        library("addPost", "Record where a video is published, from a link the owner gives you (the platform is read from the address), or with no link that it went up. Never open, sign in to or read the platform yourself.",
                [idea, field("videoID", "uuid", "A video from library.ideas[].videos[].id."),
                 field("link", "string", "The post's web link. Left out: marked posted without a link.", required: false)],
                #"{"type": "addPost", "ideaID": "IDEA-ID", "videoID": "00000000-0000-4000-8000-000000000003", "link": "https://youtube.com/shorts/abc123"}"#)
        library("setStyle", "Replace all of Style.md. Prefer addStyleRule and removeStyleRule; use this only when the owner asked for the whole text to change.",
                [field("text", "string", "All of Style.md, up to \(StyleDoc.textLimit) characters.")],
                ##"{"type": "setStyle", "text": "# Style\n\n## Shorts\n- One point per Short.\n"}"##)
        library("addStyleRule", "Add a rule to Style.md under a heading (made when missing), after the owner said yes to it. Say where it came from.",
                [field("section", "string", "The heading, like Every video, Talking head, Graphics, Shorts or Thumbnails."),
                 field("rule", "string", "The rule, one line, up to \(StyleDoc.ruleLimit) characters."),
                 field("source", "string", "Where it came from, like \"feedback on AppStore, 17 Oct\".", required: false)],
                #"{"type": "addStyleRule", "section": "Shorts", "rule": "Captions never over the face.", "source": "feedback on AppStore, 15 Oct"}"#)
        library("removeStyleRule", "Take a rule out of Style.md, when the owner asks.", [field("rule", "string", "The rule's words, as in style.sections[].rules (the source in *(…)* may be left out).")],
                #"{"type": "removeStyleRule", "rule": "Captions never over the face."}"#)
        library("removePost", "Take a post off a video.", [idea, field("videoID", "uuid", "A video from library.ideas[].videos[].id."),
                 field("link", "string", "The post to remove. Left out: all of them.", required: false)],
                #"{"type": "removePost", "ideaID": "IDEA-ID", "videoID": "00000000-0000-4000-8000-000000000003"}"#)
        library("planRelease", "Plan when a video (the long video or a Short) goes out and where, as the owner tells you: one day, an optional time, the platforms (all four unless the owner says fewer), and a platform's own day when one goes out on another day. It replaces the video's plan and shows on the owner's Calendar. Planning never posts anything.",
                [idea, field("videoID", "uuid", "A video from library.ideas[].videos[].id."),
                 field("day", "string", "The day it goes out, as yyyy-MM-dd."),
                 field("clock", "string", "The time of day, 24-hour HH:mm; left out, any time that day.", required: false),
                 field("platforms", "string[]", "Of youtube, instagram, x, linkedin. Left out: all four.", required: false),
                 field("ownDays", "object", "A platform that goes out on another day: {platform: yyyy-MM-dd}.", required: false)],
                #"{"type": "planRelease", "ideaID": "IDEA-ID", "videoID": "00000000-0000-4000-8000-000000000003", "day": "2026-10-19", "clock": "19:00", "platforms": ["youtube", "instagram", "x", "linkedin"]}"#)
        library("unplanRelease", "Take a video's plan away; it waits in the Calendar's Not planned list.", [idea, field("videoID", "uuid", "A video from library.ideas[].videos[].id.")],
                #"{"type": "unplanRelease", "ideaID": "IDEA-ID", "videoID": "00000000-0000-4000-8000-000000000003"}"#)

        let session = [field("sessionID", "uuid", "From sessions or state.", required: false),
                       field("projectID", "uuid", "From sessions or state.", required: false)]
        let methods = [
            Method(method: "manual", summary: "The Agents Manual: how to work with the owner in YamVideo, the rules, and a recipe for each common job (first edit, cuts, captions, screen and layouts, zooms, graphics, chapters and text, thumbnail, Shorts, export). Read it first, then this catalog for each command's fields.", fields: []),
            Method(method: "catalog", summary: "This description.", fields: []),
            Method(method: "sessions", summary: "Running YamVideo windows and their open projects.", fields: []),
            Method(method: "state", summary: "The project as last committed: revision, recordings with ids and timing, colour, effects, markers, the owner's selection and playhead.", fields: session),
            Method(method: "apply", summary: "1–100 commands as one undo step, all or nothing.", fields: session + [
                field("expectedRevision", "integer", "The revision you read. A newer one refuses with revision_conflict: read state again."),
                field("commands", "array", "The commands, in order."),
                field("label", "string", "What the Undo menu should call the step, at most 80 characters.", required: false),
                field("dryRun", "boolean", "Check everything and report what would happen, changing nothing.", required: false, default: .bool(false)),
                field("requestID", "string", "Retrying the same id returns the first answer instead of applying twice.", required: false)]),
            Method(method: "preview", summary: "Render one frame to a PNG on this Mac.", fields: [
                field("clip", "uuid", "The recording (or use timeSpace movie).", required: false),
                field("time", "number", "When.", unit: editedSeconds), timeSpace,
                field("composed", "boolean", "As the owner's Preview plays it: crop, zoom, colour, blur areas, effects and graphics (captions are export-only), with each graphic's box in graphics[]. Use this to see an effect, a zoom or where a graphic sits.", required: false, default: .bool(false)),
                field("short", "uuid", "One of the recording's Shorts: draws it as the Short viewer shows it, 1080×1920, with its graphics laid out for 9:16 and its burned-in captions, and each graphic's box in graphics[]. time is then seconds into the Short.", required: false),
                field("draft", "array", "Graphics to draw in this preview only, never stored: {kind, start, end, props, look?, transform?, id?} as in addGraphic, checked the same way (with composed or short). Use it to show the owner a plan before you apply it.", required: false),
                field("furniture", "boolean", "With short: draw YouTube's Shorts player over the frame as a phone shows it (the icons at the top, the like and share rail down the lower right, the channel, title and sound along the bottom) and dash the clear area, so you can see what a viewer's screen covers.", required: false, default: .bool(false)),
                field("cropped", "boolean", "Apply the crop to a source-frame preview.", required: false, default: .bool(false)),
                field("original", "boolean", "Leave the colour correction out, to compare.", required: false, default: .bool(false)),
                field("expectedRevision", "integer", "Refuse if the project has moved on.", required: false)]),
            Method(method: "events", summary: "What changed since a cursor, and who changed it.", fields: [
                field("after", "integer", "The last sequence you saw.", required: false), field("limit", "integer", "At most 100.", required: false)]),
            Method(method: "undo", summary: "Undo a step you made, by its transactionID; refused if another edit is now on top.", fields: session + [
                field("transactionID", "uuid", "From apply's result."), field("expectedRevision", "integer", "The revision you read.")]),
            Method(method: "redo", summary: "Redo it.", fields: session + [
                field("transactionID", "uuid", "From undo's result."), field("expectedRevision", "integer", "The revision you read.")]),
            Method(method: "analyze", summary: "Propose cuts, zooms or thumbnail frames as a job; applies nothing. silence: pauses (threshold, minimum, padding as in the silence review). autoEdit: the cuts the project's cut style makes, pauses and stumbles from the transcript, each with its reasons, plus the captions and audio settings an auto edit would set. thumbnailFrames: the best moments of the kept footage for a thumbnail (Apple Vision: smile, face quality, eyes open, facing the camera), best first, each with its edited time (the thumbnail design's time) and scores from 0 to 1, and sheet, a PNG of their faces to look at.", fields: session + [
                field("clip", "uuid", "The recording."), field("kind", "string", "What to look for. screenZooms: zooms on the recording's screen recording, from local activity in the part the edit shows, timed on the edited recording, with targets in the screen recording's pixels. thumbnailFrames: moments for the thumbnail; a recording with a screen uses the speaker's own picture. logos: the brand and company names said in the transcript (mentions: each name, its words, source and edited times, and source library for the owner's logos, known for the app's list of brands, guess for a word shaped like a name), missing (names without a logo yet: ask the owner for a file, then setLogo), and suggestions: a logoBadge graphic for each name with a logo, timed on the word (names said within 1.2 s share one badge; a logo said again within minimum seconds gets none; a badge ends before a layout change), ready for addGraphic.", values: AgentSessionInfo.analyzeKinds),
                field("style", "string", "For autoEdit: a cut style other than the project's.", required: false, values: CutStyle.allCases.map(\.rawValue)),
                field("limit", "integer", "For thumbnailFrames: how many moments, 1 to 20.", required: false, default: .number(8)),
                field("minimum", "number", "For logos: the seconds between two badges of one logo.", required: false, default: .number(60))]),
            Method(method: "logos", summary: "The owner's logo library: each brand's name, the words that say it, and its image's path. The library is kept for every project, in the app's own folder; analyze with kind logos uses it.", fields: []),
            Method(method: "setLogo", summary: "Add a brand's logo to the owner's library, or replace the one of the same name: the app keeps a copy of the file. Use only a logo the owner gave, or a clear, simple one you are sure of (never invent one), and show the owner each logo you keep. Returns the library.", fields: [
                field("name", "string", "The brand, as the badge's label shows it (1 to 40 characters): Next.js, Apple Watch."),
                field("path", "string", "A local PNG (transparent), JPEG, SVG, WebP or HEIC file."),
                field("words", "array", "What the speaker says for it, matched without case: [\"next.js\", \"next js\"]. 1 to 8.", required: false)]),
            Method(method: "removeLogo", summary: "Remove a logo from the owner's library. A badge that uses it cannot draw until the logo is set again, so remove or change those badges too.", fields: [
                field("name", "string", "The brand.")]),
            Method(method: "transcribe", summary: "Transcribe a recording on this Mac with whisper.cpp, as a job with progress; the words land as one undo step (Transcribe). state.autoEdit says whether whisper is installed and which models are downloaded; only the owner can download a model.", fields: session + [
                field("clip", "uuid", "The recording."),
                field("model", "string", "Default: the project's autoEdit.model.", required: false, values: TranscriptModel.allCases.map(\.rawValue)),
                field("language", "string", "A whisper language code or auto. Default: the project's autoEdit.language.", required: false)]),
            Method(method: "transcript", summary: "A recording's words in source seconds with editedStart (where each plays now; null when cut), its captions on the edited timeline, and the stumbles found in it (filler, repeat, restart, fragment). Use it to place graphics and chapters on what is said.", fields: [
                field("clip", "uuid", "The recording.")]),
            Method(method: "autoEdit", summary: "The whole auto edit by the project's answers (state.autoEdit.options), as a job: transcribe if the cut style or captions need words and there are none, find the cuts, then apply them with the captions and loudness settings as one undo step, labelled Auto Edit. With cutStyle review nothing is applied and the cuts come back for the owner to choose. The result lists every cut with its reasons, the sections and settings, and the transactionID to undo it.", fields: session + [
                field("clip", "uuid", "The recording."),
                field("style", "string", "A cut style other than the project's, for this run only.", required: false, values: CutStyle.allCases.map(\.rawValue)),
                field("label", "string", "What the Undo menu calls the step.", required: false, default: .string("Auto Edit"))]),
            Method(method: "export", summary: "Export one recording or the movie as a job. A recording's graphics are drawn in (HyperFrames renders each one once and keeps its frames, so the first export takes longer); state.graphicsRenderer says whether this Mac can, and only the owner can download HyperFrames. Movies leave graphics out.", fields: session + [
                field("path", "string", "Where to write."), field("scope", "string", "What.", values: ["recording", "movie"]),
                field("clip", "uuid", "For scope recording.", required: false), field("overwrite", "boolean", "Replace an existing file.", required: false, default: .bool(false)),
                field("youtube", "boolean", "Export for YouTube: path is an existing folder, and it gets the MP4, the captions as an SRT on the edited timeline, a 1280×720 thumbnail under 2 MB, the upload text and a JSON of the same (with an end screen: when it starts and which element goes in which box, to place in YouTube Studio, as its upload API cannot). Refused while state.clips[].publishIssues has a blocking issue.", required: false, default: .bool(false)),
                field("short", "uuid", "Export one of the recording's Shorts (with clip): a 1080×1920 MP4 to path, or with youtube into the folder path its MP4, its captions as an SRT on its own timeline, a 1080×1920 cover JPEG, the upload text and a JSON (short: true; the related-video link to set in YouTube Studio, which the upload API cannot). Refused while state.clips[].shorts[].issues has a blocking issue.", required: false)]),
            Method(method: "thumbnail", summary: "Make the recording's thumbnail from its design (state.clips[].publish.design): the frame, the speaker cut out with Apple Vision, the title, tag and picture, at 1280×720. Returns the PNG's path to look at, whether a speaker was found and where; changes nothing unless saved. To use it: save, then setPublishInfo with {thumbnail: savedPath, design: …}.", fields: [
                field("clip", "uuid", "The recording."),
                field("design", "object", "Design keys to try over the stored design, without storing them.", required: false),
                field("save", "boolean", "Also save the PNG next to the recording and return savedPath.", required: false, default: .bool(false)),
                field("check", "boolean", "Also run the phone check: check.findings says what does not read in 0.5 s at the size of a phone's YouTube home feed (390×219 pt) and search list (168×94 pt). Each finding has kind (textSize: letters under \(Int(PhoneCheck.letterLimits.reads)) pt; words: more than \(PhoneCheck.wordLimits.reads) words in the tag, title and picture; contrast: words under \(PhoneCheck.contrastLimits.reads):1 against what is behind them; face: a face under \(Int(PhoneCheck.faceLimits.reads)) pt high, or none), level (fails: does not read in 0.5 s; weak: reads, but not at a glance), sizes (homeFeed, searchList) and message. check also has reads (no findings), words, titleSize (px of 1920), face (its box in px of 1920×1080) and phone, a PNG of the design at both sizes to look at.", required: false, default: .bool(false))]),
            Method(method: "job", summary: "A job's status and result.", fields: [field("job", "uuid", "From analyze, transcribe, autoEdit or export.")]),
            Method(method: "cancel", summary: "Cancel a job.", fields: [field("job", "uuid", "From analyze, transcribe, autoEdit or export.")]),
            Method(method: "save", summary: "Save without a dialog: in place, first save, or a copy to another path.", fields: session + [
                field("path", "string", "Where, for a first save or a copy.", required: false)]),
            Method(method: "reveal", summary: "Show the owner something: select it and move the playhead there. Changes no edits.", fields: [
                field("clip", "uuid", "A recording.", required: false), field("section", "uuid", "A section.", required: false),
                field("zoom", "uuid", "A zoom.", required: false), field("effect", "uuid", "A blur effect.", required: false),
                field("marker", "uuid", "A marker.", required: false), field("graphic", "uuid", "A graphic.", required: false),
                field("short", "uuid", "A Short: selects it and shows it in the Short viewer; time is then seconds into it.", required: false),
                field("layout", "uuid", "A screen layout: selects it and moves the playhead to it.", required: false),
                field("idea", "uuid", "An idea: shows it on the Library page.", required: false),
                field("time", "number", "A time.", required: false, unit: editedSeconds), timeSpace]),
            Method(method: "library", summary: "The Library: the owner's ideas and videos (title, notes, topic, links, images with their paths to look at, stage idea, inProduction, ready or posted, the linked project and whether it is open, and videos: each long video and Short of the project with its exports, posts and the exported files' paths), the topics in use, the Library's revision and its top undo and redo steps. The Library spans every project; state.idea says which idea the open project was made from.", fields: []),
            Method(method: "libraryApply", summary: "1–100 Library commands (libraryCommands) as one undo step in the Library's own history, all or nothing.", fields: [
                field("expectedRevision", "integer", "The Library revision you read (library.revision), not the project's."),
                field("commands", "array", "The Library commands, in order."),
                field("label", "string", "What the Undo menu on the Library page should call the step, at most 80 characters.", required: false),
                field("dryRun", "boolean", "Check everything and report what would happen, changing and copying nothing.", required: false, default: .bool(false)),
                field("requestID", "string", "Retrying the same id returns the first answer instead of applying twice.", required: false)]),
            Method(method: "libraryUndo", summary: "Undo a Library step you made, by its transactionID; refused if another Library change is now on top.", fields: [
                field("transactionID", "uuid", "From libraryApply's result."), field("expectedRevision", "integer", "The Library revision you read.")]),
            Method(method: "style", summary: "Style.md, the channel's editing rules: the whole text and each section's rules. Read it before you edit, and follow it unless the owner says otherwise. Change it with libraryApply (addStyleRule after the owner says yes).", fields: []),
            Method(method: "scanFolder", summary: "What Add Past Videos would find under a folder: each YamVideo project with the Export for YouTube files made from it (matched by project, Short or title), exports whose project is not there, and whether the Library already holds each. Changes nothing; importVideos adds them.", fields: [
                field("path", "string", "A folder, a .yamvideo project or a .youtube.json export.")]),
            Method(method: "libraryRedo", summary: "Redo it.", fields: [
                field("transactionID", "uuid", "From libraryUndo's result."), field("expectedRevision", "integer", "The Library revision you read.")]),
        ]

        return AgentCatalog(
            conventions: [
                "Recording times are seconds of the edited recording — after cuts, reordering and speed changes. Trim bounds and section ranges are seconds of the source file. Movie times are only used where timeSpace is \"movie\".",
                "Values are checked, never clamped: an out-of-range value is refused with a message saying what is allowed. Times snap to whole frames and rectangles to even pixels; state shows exactly what was stored.",
                "Rectangles are {x, y, width, height} and points {x, y} in source pixels with the origin at the top left of the displayed (rotation-applied) frame.",
                "Examples use made-up ids (00000000-…); use real ids from state.",
                "Commands in one apply all see the state you read, not each other's results. To refer to something you add in the same request, choose its id yourself (areaID, zoomID, effectID, markerID).",
                "Effects, zooms, markers and screen layouts follow the footage they are on: cutting that footage removes them (apply's result lists removedZooms, removedEffects, removedMarkers and removedLayouts; undo restores them).",
                "The owner edits too. Every apply names the revision you read; revision_conflict means read state again and re-plan, not retry blindly. agents_paused means the owner has paused agents.",
                "The Library (ideas) is separate from the open project: it has its own revision (library.revision), its own commands (libraryCommands, sent with libraryApply) and its own undo history. Events of kind library carry the Library's revision.",
                "YamVideo never posts to or reads from YouTube, Instagram, X or LinkedIn, and agents must not either: the owner publishes by hand.",
            ],
            workflow: [
                "Read the manual (method manual) once per session: it has the rules and a recipe for each common job.",
                "Read the channel's Style.md (method style) before you edit, and follow it.",
                "Read state.",
                "For a first edit of a talking-head recording, follow the owner's answers in state.autoEdit.options: run autoEdit (it transcribes, cuts and sets captions and loudness), then read transcript to place graphics and chapters on what is said.",
                "Plan, then apply with dryRun to check the batch.",
                "Apply for real with a label the owner will understand in the Undo menu.",
                "Look at the result with preview (composed: true to see effects and zooms; short to see a Short).",
                "For a YouTube Short from a long recording: addShort on its best minute or two (window: \"speaker\"), give it its own title, check it with preview and short at a few times, then export with short and youtube.",
                "For a walkthrough with a separate screen recording: setScreen on the speaker's recording with the offset that syncs them (check with preview composed at a moment both show, such as a click), cut the speaker as usual, then replaceLayouts from the transcript (speaker for the intro and the outro, split while the speaker explains, the screen layout while the screen shows the point).",
                "Undo your own step by transactionID if it is not right; reveal to show the owner what you did.",
                "For ideas: read library, add or sharpen ideas with libraryApply in the owner's words, reuse library.topics, and link a project to its idea with linkProject. reveal with idea shows one to the owner.",
            ],
            commands: commands, libraryCommands: libraryCommands, methods: methods)
    }()

    /// Kept here rather than read from `AppModel` so the catalog needs no instance.
    static let exportSettingKeys: Set<String> = AppModel.exportSettingKeys
}
