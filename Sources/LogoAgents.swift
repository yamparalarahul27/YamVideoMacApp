import Foundation

// Logo badges for local agents: analyze with kind logos finds the brands said in a
// recording and suggests badges, and the owner's logo library (`LogoLibrary`) is read with
// the logos request and changed with setLogo and removeLogo.

/// The result of analyze with kind logos.
struct AgentBrands: Encodable {
    struct Missing: Encodable {
        var name: String
        var source: BrandMention.Source
        /// Edited seconds of each time it is said.
        var times: [Double]
    }
    struct Suggestion: Encodable {
        var names: [String]
        var start: Double
        var end: Double
        /// What the layout shows when the badge starts: speaker, screen or split.
        var layout: String?
        /// Ready for addGraphic or replaceGraphics.
        var graphic: Graphic
    }
    struct Skip: Encodable { var name: String; var time: Double?; var reason: String }
    var kind = "logos"
    var mentions: [BrandMention]
    /// Names said in the kept recording that have no logo yet: ask the owner for a file,
    /// then setLogo. Guesses are words shaped like names; check them first.
    var missing: [Missing]
    var suggestions: [Suggestion]
    var skipped: [Skip]
    var library: String
}

/// One logo of the library, as agents see it.
struct AgentLogo: Encodable {
    var name: String
    var words: [String]
    var path: String
}

struct AgentLogos: Encodable {
    var folder: String
    var logos: [AgentLogo]
}

extension AppModel {
    /// analyze with kind logos, for one recording.
    func brandAnalysis(_ item: VideoItem, gap: Double) -> AgentBrands? {
        guard let found = item.brandPlan(gap: gap) else { return nil }
        let kept = found.mentions.filter { $0.time != nil }
        var missing: [AgentBrands.Missing] = []
        for mention in kept where mention.logo == nil {
            if let index = missing.firstIndex(where: { $0.name == mention.name }) { missing[index].times.append(mention.time!) }
            else { missing.append(.init(name: mention.name, source: mention.source, times: [mention.time!])) }
        }
        let suggestions = zip(found.plan.badges, found.plan.shown).map { badge, group in
            AgentBrands.Suggestion(names: group.map(\.name), start: badge.start, end: badge.end,
                                   layout: item.screen?.layout(at: badge.start, endScreen: item.graphics?.endScreen?.start).rawValue,
                                   graphic: badge)
        }
        return AgentBrands(mentions: found.mentions, missing: missing, suggestions: suggestions,
                           skipped: found.plan.skipped.filter { $0.mention.time != nil }
                               .map { .init(name: $0.mention.name, time: $0.mention.time, reason: $0.reason) },
                           library: LogoLibrary.folder.path)
    }

    static func agentLogos() -> AgentLogos {
        AgentLogos(folder: LogoLibrary.folder.path,
                   logos: LogoLibrary.load().map { AgentLogo(name: $0.name, words: $0.words, path: LogoLibrary.path(of: $0)) })
    }

    /// setLogo: a copy of the owner's file into the library, under `name`.
    func agentSetLogo(_ request: AgentRequest) -> Result<AgentLogos, EditError> {
        guard let name = request.name, let path = request.path else {
            return .failure(.invalid("setLogo needs name (the brand) and path (the logo file)."))
        }
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
        do { try LogoLibrary.set(name: name, image: url, words: request.words) }
        catch let error as EditError { return .failure(error) }
        catch { return .failure(.invalid("The logo could not be kept: \(error.localizedDescription)")) }
        appendEvent(.job, origin: agentOrigin(request), label: "Logo \(name) kept", clips: [])
        return .success(Self.agentLogos())
    }

    func agentRemoveLogo(_ request: AgentRequest) -> Result<AgentLogos, EditError> {
        guard let name = request.name else { return .failure(.invalid("removeLogo needs name.")) }
        do { try LogoLibrary.remove(name: name) }
        catch let error as EditError { return .failure(error) }
        catch { return .failure(.invalid("The logo could not be removed: \(error.localizedDescription)")) }
        appendEvent(.job, origin: agentOrigin(request), label: "Logo \(name) removed", clips: [])
        return .success(Self.agentLogos())
    }
}
