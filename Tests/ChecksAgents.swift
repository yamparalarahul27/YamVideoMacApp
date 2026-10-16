// Checks for agents. Run with ./test.sh agents
import AppKit
import AVFoundation
import Foundation

@MainActor func agentsTests() async throws {
    let commandClip = roundTripProject.clips[0]
    let sectionA = commandClip.timeline.segments[0], sectionB = commandClip.timeline.segments[1]
    // MARK: - Local agent bridge

    print("\nLocal agent bridge")

    let agentEditor = freshEditor()
    let agentClip = agentEditor.items[0].id.uuidString
    let firstState = agentResult(await agentCall(agentEditor, ["method": "state"]))
    let stateClips = firstState["clips"] as? [[String: Any]] ?? []
    let stateSections = stateClips.first?["sections"] as? [[String: Any]] ?? []
    check(stateClips.count == 1 && stateSections.count == 2 && (stateClips.first?["zooms"] as? [Any])?.count == 1,
          "state lists recordings with their sections and zooms")
    check(abs((stateSections.last?["editedStart"] as? Double ?? 0) - 1.5) < 0.0001, "state gives each section's edited start")
    equal(firstState["revision"] as? Int, agentEditor.revision, "state reports the current revision")

    var speedUp = address(agentEditor)
    speedUp["method"] = "apply"; speedUp["requestID"] = "speed-1"; speedUp["client"] = "Codex"; speedUp["label"] = "Speed up the intro"
    speedUp["commands"] = [["type": "setSectionSpeed", "clipID": agentClip, "sectionID": sectionA.id.uuidString, "speed": 1.5]]
    let applied = await agentCall(agentEditor, speedUp)
    check(applied["ok"] as? Bool == true && agentEditor.items[0].timeline.segments[0].speed == 1.5, "an agent's apply edits the open project")
    equal(agentEditor.undoTitle, "Undo Speed up the intro (Codex)", "the agent's label and name reach the Undo menu")
    check(agentEditor.agentHighlight?.origin == "Codex" && agentEditor.agentHighlight?.elements.contains(sectionA.id) == true
              && agentEditor.agentHighlight?.clips == [agentEditor.items[0].id],
          "an agent's change is highlighted on exactly the section it changed")
    equal(agentEditor.statusMessage, "Codex: Speed up the intro", "the status line says which agent did what")
    check(agentEditor.recentActivity.first?.origin == .agent("Codex") && agentEditor.recentActivity.first?.label == "Speed up the intro",
          "the activity list records the agent's step")
    equal(agentEditor.agentClients.first?.name, "Codex", "the Local agents panel knows who connected")
    let clientsBeforeDiscovery = agentEditor.agentClients
    _ = await agentCall(agentEditor, ["method": "sessions"])
    equal(agentEditor.agentClients, clientsBeforeDiscovery, "discovery alone is not counted as an agent's activity")
    agentEditor.agentHighlight = nil
    agentEditor.perform([.setAspect(clip: agentEditor.items[0].id, preset: "4:5")])
    check(agentEditor.agentHighlight == nil && agentEditor.recentActivity.first?.origin == .human,
          "the owner's own edits are listed but not highlighted")
    equal(AgentSetup.quoted("/Users/me/YamVideo/build/yamvideoctl"), "/Users/me/YamVideo/build/yamvideoctl",
          "plain paths are pasted as they are")
    equal(AgentSetup.quoted("/Users/me/My Videos/it's/yamvideoctl"), #"'/Users/me/My Videos/it'\''s/yamvideoctl'"#,
          "paths with spaces or quotes are quoted for the shell")
    equal(AgentSetup.claudeCommand(ctl: "/a/yamvideoctl", server: "/a/server.mjs"),
          "claude mcp add yamvideo -s user -e YAMVIDEO_CLIENT=Claude -e YAMVIDEO_CTL=/a/yamvideoctl -- node /a/server.mjs",
          "the Claude Code command matches claude mcp add's syntax")
    equal(AgentSetup.codexCommand(ctl: "/a/yamvideoctl", server: "/a/server.mjs"),
          "codex mcp add yamvideo --env YAMVIDEO_CLIENT=Codex --env YAMVIDEO_CTL=/a/yamvideoctl -- node /a/server.mjs",
          "the Codex command matches codex mcp add's documented syntax")
    let stepsBeforeRetry = agentEditor.undoEntries.count, revisionBeforeRetry = agentEditor.revision
    let retried = await agentCall(agentEditor, speedUp)
    check(NSDictionary(dictionary: retried).isEqual(to: applied) && agentEditor.undoEntries.count == stepsBeforeRetry
              && agentEditor.revision == revisionBeforeRetry,
          "retrying a request ID returns the original answer without applying twice")
    var reused = speedUp
    reused["commands"] = [["type": "setSectionSpeed", "clipID": agentClip, "sectionID": sectionA.id.uuidString, "speed": 2]]
    equal(agentError(await agentCall(agentEditor, reused)), "request_id_reused", "a request ID reused for different edits is refused")
    var stale = speedUp
    stale["requestID"] = "speed-2"; stale["commands"] = [["type": "setAspect", "clipID": agentClip, "preset": "1:1"]]
    let staleAnswer = await agentCall(agentEditor, stale)
    check(agentError(staleAnswer) == "revision_conflict"
              && (staleAnswer["error"] as? [String: Any])?["currentRevision"] as? Int == agentEditor.revision,
          "a stale revision is refused with the current one")
    var noID = address(agentEditor)
    noID["method"] = "apply"; noID["commands"] = [["type": "setAspect", "clipID": agentClip, "preset": "1:1"]]
    equal(agentError(await agentCall(agentEditor, noID)), "invalid_request", "an edit without a request ID is refused")
    var otherSession = address(agentEditor)
    otherSession["sessionID"] = UUID().uuidString; otherSession["method"] = "apply"; otherSession["requestID"] = "x-1"
    otherSession["commands"] = [["type": "setAspect", "clipID": agentClip, "preset": "1:1"]]
    equal(agentError(await agentCall(agentEditor, otherSession)), "wrong_session", "an edit for another session is refused")
    var tooMany = address(agentEditor)
    tooMany["method"] = "apply"; tooMany["requestID"] = "many"
    tooMany["commands"] = Array(repeating: ["type": "setAspect", "clipID": agentClip, "preset": "1:1"], count: 101)
    equal(agentError(await agentCall(agentEditor, tooMany)), "invalid_request", "more than 100 commands is refused")
    var unknownType = address(agentEditor)
    unknownType["method"] = "apply"; unknownType["requestID"] = "unknown"; unknownType["commands"] = [["type": "explode"]]
    equal(agentError(await agentCall(agentEditor, unknownType)), "unsupported_capability", "an unknown command type is named as unsupported")
    var missingField = address(agentEditor)
    missingField["method"] = "apply"; missingField["requestID"] = "missing"; missingField["commands"] = [["type": "setCrop", "clipID": agentClip]]
    let missingAnswer = await agentCall(agentEditor, missingField)
    check(((missingAnswer["error"] as? [String: Any])?["message"] as? String ?? "").contains("rect"),
          "a command missing a field names the field")

    var settingsPatch = address(agentEditor)
    settingsPatch["method"] = "apply"; settingsPatch["requestID"] = "gif"
    settingsPatch["commands"] = [["type": "setExportSettings", "settings": ["format": "gif", "frameRate": 12]]]
    check(await agentCall(agentEditor, settingsPatch)["ok"] as? Bool == true && agentEditor.settings.format == .gif
              && agentEditor.settings.frameRate == .fps12 && agentEditor.settings.quality == ExportSettings().quality,
          "a settings patch changes only the settings it names")
    var badPatch = address(agentEditor)
    badPatch["method"] = "apply"; badPatch["requestID"] = "bad-gif"
    badPatch["commands"] = [["type": "setExportSettings", "settings": ["colour": "blue"]]]
    equal(agentError(await agentCall(agentEditor, badPatch)), "invalid_command", "an unknown setting is refused")

    var movieSplit = address(agentEditor)
    movieSplit["method"] = "apply"; movieSplit["requestID"] = "movie-split"
    movieSplit["commands"] = [["type": "splitSection", "at": 0.5, "timeSpace": "movie"]]
    let movieSplitAnswer = await agentCall(agentEditor, movieSplit)
    check(movieSplitAnswer["ok"] as? Bool == true && agentEditor.items[0].timeline.segments.count == 3,
          "movie time is mapped to its recording when asked for explicitly")

    let undoStep = (agentResult(await agentCall(agentEditor, ["method": "state"]))["history"] as? [String: Any])?["undo"] as? [String: Any]
    var undoMine = address(agentEditor)
    undoMine["method"] = "undo"; undoMine["requestID"] = "undo-split"; undoMine["transactionID"] = undoStep?["transactionID"] ?? ""
    check(await agentCall(agentEditor, undoMine)["ok"] as? Bool == true && agentEditor.items[0].timeline.segments.count == 2,
          "an agent undoes the step it names from state")
    var undoAcross = address(agentEditor)
    undoAcross["method"] = "undo"; undoAcross["requestID"] = "undo-old"; undoAcross["transactionID"] = UUID().uuidString
    equal(agentError(await agentCall(agentEditor, undoAcross)), "history_conflict", "undoing a step that is not on top is refused")

    let feed = agentResult(await agentCall(agentEditor, ["method": "events", "after": 0]))
    check((feed["events"] as? [[String: Any]] ?? []).contains { $0["origin"] as? String == "Codex" && $0["kind"] as? String == "edit" },
          "the event feed names the agent behind each edit")
    for _ in 0..<1100 { agentEditor.appendEvent(.edit, origin: .human, label: "filler") }
    equal(agentError(await agentCall(agentEditor, ["method": "events", "after": 1])), "resync_required",
          "a cursor older than the kept feed must resync")

    let frame = agentResult(await agentCall(agentEditor, ["method": "preview", "clip": agentClip, "time": 0.4]))
    check(FileManager.default.fileExists(atPath: frame["path"] as? String ?? "") && frame["revision"] as? Int == agentEditor.revision,
          "a preview is a PNG file tagged with the revision it shows")
    agentEditor.perform([.setCrop(clip: agentEditor.items[0].id, rect: CGRect(x: 100, y: 60, width: 640, height: 360))])
    let croppedFrame = agentResult(await agentCall(agentEditor, ["method": "preview", "clip": agentClip, "time": 0.4, "cropped": true]))
    check(croppedFrame["width"] as? Int == 640 && croppedFrame["height"] as? Int == 360, "a cropped preview has the crop's size")

    var firstSave = address(agentEditor)
    firstSave["method"] = "save"; firstSave["requestID"] = "save-0"
    equal(agentError(await agentCall(agentEditor, firstSave)), "invalid_request", "saving an untitled project needs a path")
    let agentProjectFile = scratch.appendingPathComponent("agent.yamvideo")
    firstSave["requestID"] = "save-1"; firstSave["path"] = agentProjectFile.path
    check(await agentCall(agentEditor, firstSave)["ok"] as? Bool == true && agentEditor.projectURL == agentProjectFile,
          "an agent can give an untitled project its first file")
    var external = try JSONDecoder().decode(VideoProject.self, from: Data(contentsOf: agentProjectFile))
    external.settings.quality = 5
    try JSONEncoder().encode(external).write(to: agentProjectFile)
    var inPlace = address(agentEditor)
    inPlace["method"] = "save"; inPlace["requestID"] = "save-2"
    equal(agentError(await agentCall(agentEditor, inPlace)), "disk_conflict", "saving over a file changed on disk is refused")
    check(agentEditor.diskConflict(at: agentProjectFile), "the app sees the external change too")
    var saveCopy = address(agentEditor)
    saveCopy["method"] = "save"; saveCopy["requestID"] = "save-3"; saveCopy["path"] = scratch.appendingPathComponent("agent-copy.yamvideo").path
    let copied = agentResult(await agentCall(agentEditor, saveCopy))
    check(copied["copy"] as? Bool == true && copied["projectID"] as? String != agentEditor.projectID.uuidString
              && agentEditor.projectURL == agentProjectFile, "saving to another path writes a copy with its own identity")

    var analysis = address(agentEditor)
    analysis["method"] = "analyze"; analysis["requestID"] = "zooms-1"; analysis["kind"] = "zooms"; analysis["clip"] = agentClip
    let analysisJob = agentResult(await agentCall(agentEditor, analysis))
    let analysed = try await waitForJob(agentEditor, analysisJob["id"] as? String ?? "")
    check(analysed["status"] as? String == "succeeded" && (analysed["result"] as? [String: Any])?["suggestions"] is [Any]
              && analysed["sourceRevision"] as? Int == agentEditor.revision,
          "zoom analysis runs as a job and returns suggestions for the revision it read")
    let zoomCount = agentEditor.items[0].zoomShots.count
    equal(agentEditor.items[0].zoomShots.count, zoomCount, "analysis applies nothing by itself")

    var mp4Again = address(agentEditor)
    mp4Again["method"] = "apply"; mp4Again["requestID"] = "mp4"
    mp4Again["commands"] = [["type": "setExportSettings", "settings": ["format": "mp4"]]]
    _ = await agentCall(agentEditor, mp4Again)
    var exportWrongType = address(agentEditor)
    exportWrongType["method"] = "export"; exportWrongType["requestID"] = "export-1"; exportWrongType["clip"] = agentClip
    exportWrongType["path"] = scratch.appendingPathComponent("agent.gif").path
    equal(agentError(await agentCall(agentEditor, exportWrongType)), "invalid_command", "an export path must match the format")
    let agentExport = scratch.appendingPathComponent("agent-export.mp4")
    var exporting = address(agentEditor)
    exporting["method"] = "export"; exporting["requestID"] = "export-2"; exporting["clip"] = agentClip; exporting["path"] = agentExport.path
    let exportJob = agentResult(await agentCall(agentEditor, exporting))
    check(agentEditor.isConverting, "an agent's export locks editing like the owner's does")
    var duringExport = address(agentEditor)
    duringExport["method"] = "apply"; duringExport["requestID"] = "during"
    duringExport["commands"] = [["type": "setAspect", "clipID": agentClip, "preset": "1:1"]]
    equal(agentError(await agentCall(agentEditor, duringExport)), "export_in_progress", "edits wait for an export to finish")
    let exported = try await waitForJob(agentEditor, exportJob["id"] as? String ?? "")
    check(exported["status"] as? String == "succeeded" && FileManager.default.fileExists(atPath: agentExport.path) && !agentEditor.isConverting,
          "the export job publishes its file and unlocks editing")
    let agentSourceCopy = scratch.appendingPathComponent("agent-source.mp4")
    try? FileManager.default.removeItem(at: agentSourceCopy)
    try FileManager.default.copyItem(at: landscape, to: agentSourceCopy)
    var agentSourceClip = ProjectClip(VideoItem(url: agentSourceCopy))
    agentSourceClip.info = info; agentSourceClip.crop = info.fullFrame
    agentEditor.perform([.addMedia([agentSourceClip])])
    var replaceSource = address(agentEditor)
    replaceSource["method"] = "export"; replaceSource["requestID"] = "export-3"; replaceSource["clip"] = agentClip
    replaceSource["path"] = agentSourceCopy.path; replaceSource["overwrite"] = true
    let sourceRefusal = await agentCall(agentEditor, replaceSource)
    check(agentError(sourceRefusal) == "invalid_command"
              && ((sourceRefusal["error"] as? [String: Any])?["message"] as? String ?? "").contains("source recording"),
          "an export can never replace a source recording, even with overwrite")

    let revealed = agentResult(await agentCall(agentEditor, ["method": "reveal", "clip": agentClip, "section": sectionB.id.uuidString]))
    check(agentEditor.selectedSegmentID == sectionB.id && revealed["section"] as? String == sectionB.id.uuidString,
          "reveal navigates only when an agent asks it to")

    // The real transport: a socket, a discovery record and separate yamvideoctl processes.
    let bridgeDir = scratch.appendingPathComponent("bridge", isDirectory: true)
    let sharedEditor = freshEditor()
    let server = LocalAgentServer(instanceID: bridgeInstance) { line in await sharedEditor.handleAgentRequest(line, instanceID: bridgeInstance) }
    try server.start(discoveryDirectory: bridgeDir)
    let socketPath = server.socketPath ?? ""
    check(socketPath.utf8.count <= LocalSocket.maxPathLength, "the socket path fits the platform limit")
    var socketStat = stat()
    check(lstat(socketPath, &socketStat) == 0 && socketStat.st_mode & 0o777 == 0o600, "the socket is private to this user")
    let recordAttributes = try FileManager.default.attributesOfItem(atPath: server.recordURL!.path)
    equal((recordAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o600, "the discovery record is private to this user")

    let ctl = ProcessInfo.processInfo.environment["YAMVIDEO_CTL"] ?? "build/yamvideoctl"
    let cliState = try await Shell.run(ctl, ["--bridge-dir", bridgeDir.path, "state"])
    equal(cliState.status, 0, "yamvideoctl reads state over the socket")
    let cliStateResult = agentResult(ctlJSON(cliState))
    let cliSession = cliStateResult["sessionID"] as? String ?? "", cliProject = cliStateResult["projectID"] as? String ?? ""
    let cliRevision = cliStateResult["revision"] as? Int ?? -1
    let editsA = scratch.appendingPathComponent("codex-edits.json"), editsB = scratch.appendingPathComponent("claude-edits.json")
    try JSONSerialization.data(withJSONObject: [["type": "addBlurArea", "clipID": agentClip,
        "rect": ["x": 40, "y": 40, "width": 200, "height": 120]]]).write(to: editsA)
    try JSONSerialization.data(withJSONObject: [["type": "setAspect", "clipID": agentClip, "preset": "16:9"]]).write(to: editsB)
    func applyArguments(_ file: URL, _ client: String, _ revision: Int) -> [String] {
        ["--bridge-dir", bridgeDir.path, "apply", "--file", file.path, "--session", cliSession, "--project", cliProject,
         "--revision", String(revision), "--client", client]
    }
    async let codexRun = Shell.run(ctl, applyArguments(editsA, "Codex", cliRevision))
    async let claudeRun = Shell.run(ctl, applyArguments(editsB, "Claude", cliRevision))
    let (codexResult, claudeResult) = try await (codexRun, claudeRun)
    let statuses = [codexResult.status, claudeResult.status].sorted()
    check(statuses == [0, 1], "two clients editing at the same revision: one commits, one is refused",
          "\(codexResult.stdoutText) \(claudeResult.stdoutText)")
    let loser = codexResult.status == 1 ? ("Codex", editsA) : ("Claude", editsB)
    equal(agentError(ctlJSON(codexResult.status == 1 ? codexResult : claudeResult)), "revision_conflict",
          "the refused client is told its revision is stale")
    sharedEditor.splitAtPlayhead()
    sharedEditor.setPreviewFraction(0.3)
    sharedEditor.splitAtPlayhead()
    let reread = agentResult(ctlJSON(try await Shell.run(ctl, ["--bridge-dir", bridgeDir.path, "state"])))
    let retry = try await Shell.run(ctl, applyArguments(loser.1, loser.0, reread["revision"] as? Int ?? -1))
    equal(retry.status, 0, "after rereading, the refused client's edit commits")
    let finalClip = sharedEditor.items[0]
    check(finalClip.blurRegions.count == 1 && finalClip.aspectLabel == "16:9" && finalClip.timeline.segments.count > 2,
          "the owner and both clients' edits all survive: no lost updates")
    let origins = Set(sharedEditor.undoEntries.map(\.origin))
    check(origins.contains(.agent("Codex")) && origins.contains(.agent("Claude")) && origins.contains(.human),
          "one shared history credits the owner, Codex and Claude")
    let noArgs = try await Shell.run(ctl, ["--bridge-dir", bridgeDir.path, "apply", "--file", editsA.path])
    check(noArgs.status == 2 && cliState.stdoutText.isEmpty == false, "an edit without session, project and revision is a usage error")

    // Endpoint checks: no symlinks, no oversize requests, no stale records.
    let symlink = scratch.appendingPathComponent("bridge-link")
    try? FileManager.default.removeItem(at: symlink)
    try FileManager.default.createSymbolicLink(atPath: symlink.path, withDestinationPath: socketPath)
    do { try LocalSocket.verifyEndpoint(symlink.path); check(false, "a symlinked socket is refused") }
    catch let error as AgentTransportError { equal(error.code, "untrusted_endpoint", "a symlinked socket is refused") }
    let oversize = try await Task.detached {
        try LocalSocket.request(Data(repeating: 0x20, count: AgentProtocol.maxRequestBytes + 10), socketPath: socketPath, timeout: 10)
    }.value
    check(String(data: oversize, encoding: .utf8)?.contains("request_too_large") == true, "an oversize request gets a bounded error")
    let staleRecord = bridgeDir.appendingPathComponent("\(UUID().uuidString).json")
    try AgentProtocol.encoder.encode(AgentDiscoveryRecord(protocolVersion: 1, instanceID: UUID(), processID: 999_999,
                                                            socketPath: "/tmp/not-a-socket", startedAt: Date())).write(to: staleRecord)
    LocalAgentServer.removeStaleRecords(in: bridgeDir)
    check(!FileManager.default.fileExists(atPath: staleRecord.path), "a record left by a dead instance is removed")
    check(FileManager.default.fileExists(atPath: server.recordURL!.path), "a live instance's record is kept")
    let repository = ProcessInfo.processInfo.environment["YAMVIDEO_ROOT"] ?? FileManager.default.currentDirectoryPath
    let demo = try await Shell.run("/usr/bin/env", ["YAMVIDEO_AGENT_BRIDGE_DIR=\(bridgeDir.path)", "YAMVIDEO_CTL=\(ctl)",
                                                     "/bin/bash", "\(repository)/Tools/YamVideoCLI/demo.sh"])
    check(demo.status == 0 && demo.stdoutText.contains("Both edits are in the open project"),
          "the two-client demo script runs end to end", demo.stdoutText)
    // The MCP adapter, driven by the official MCP client exactly as Claude Code or Codex would.
    let adapter = "\(repository)/Tools/AgentBridge"
    if FileManager.default.fileExists(atPath: "\(adapter)/node_modules/@modelcontextprotocol/sdk") {
        let node = ["/opt/homebrew/bin/node", "/usr/local/bin/node"].first { FileManager.default.isExecutableFile(atPath: $0) } ?? "node"
        let smoke = try await Shell.run("/usr/bin/env", ["YAMVIDEO_AGENT_BRIDGE_DIR=\(bridgeDir.path)", "YAMVIDEO_CTL=\(ctl)",
                                                          "YAMVIDEO_CLIENT=Claude", node, "\(adapter)/smoke.mjs"])
        check(smoke.status == 0, "the MCP adapter lists tools, describes the app, reads, dry-runs, applies, conflicts, previews, undoes and adds an idea",
              smoke.stdoutText + smoke.stderrText)
        check(sharedEditor.recentActivity.contains { $0.origin == .agent("Claude") && $0.label == "Smoke test blur" },
              "an edit through MCP is credited to the client named in its config")
    } else {
        print("  --   MCP adapter check skipped (run npm ci in Tools/AgentBridge)")
    }
    let recordPath = server.recordURL!.path
    server.stop()
    check(!FileManager.default.fileExists(atPath: socketPath) && !FileManager.default.fileExists(atPath: recordPath),
          "stopping removes the socket and the record")
    let notRunning = try await Shell.run(ctl, ["--bridge-dir", bridgeDir.path, "state"])
    check(notRunning.status == 2 && agentError(ctlJSON(notRunning)) == "app_not_running",
          "with YamVideo closed, yamvideoctl says so instead of guessing")

}
