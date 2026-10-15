// yamvideoctl — lets a local agent (or a person) read and edit the project open in a
// running YamVideo on this Mac. Built from this file plus Sources/AgentProtocol.swift
// only: it speaks the protocol and knows nothing else about the app.

import Darwin
import Foundation

let usage = """
yamvideoctl — read and edit the project open in YamVideo on this Mac

Reading
  yamvideoctl catalog                            every command, with fields, units, ranges and examples
  yamvideoctl sessions
  yamvideoctl state
  yamvideoctl events [--after N] [--limit N]
  yamvideoctl preview --clip ID --time SECONDS [--composed] [--cropped] [--original] [--revision N]
  yamvideoctl preview --movie --time SECONDS
  yamvideoctl job JOB [--wait]

Editing (always against the revision you read: --session, --project, --revision)
  yamvideoctl apply --file EDITS.json [--dry-run] [--label TEXT]
  yamvideoctl undo --transaction ID
  yamvideoctl redo --transaction ID
  yamvideoctl save [--path FILE.yamvideo] [--overwrite]
  yamvideoctl export --path OUT.mp4 (--clip ID | --movie) [--overwrite]
  yamvideoctl export --youtube --path FOLDER --clip ID [--overwrite]   video, captions, thumbnail and upload text
  yamvideoctl analyze --kind silence|zooms --clip ID
  yamvideoctl cancel JOB
  yamvideoctl reveal [--clip ID] [--section ID] [--zoom ID] [--effect ID] [--marker ID] [--graphic ID] [--time SECONDS] [--movie]
  yamvideoctl request --file REQUEST.json        send a raw protocol request

EDITS.json is a list of commands, or an object with "commands" and optionally
"sessionID", "projectID", "expectedRevision" and "label". Use "-" to read stdin.

Options
  --session ID --project ID --revision N   what the edit was planned against
  --client NAME        who to credit in Undo and the activity feed
                       (default: $YAMVIDEO_CLIENT, else "yamvideoctl")
  --request-id ID      reuse to retry safely; a retry is never applied twice
  --instance ID        when more than one YamVideo is running
  --timeout SECONDS    default 120
  --pretty             indent the JSON

Output is the app's JSON response. Exit status: 0 done, 1 refused by YamVideo
(the response says why), 2 usage or connection problem.
"""

// MARK: - Arguments

struct Arguments {
    var command = ""
    var values: [String: String] = [:]
    var flags: Set<String> = []
    var positional: [String] = []

    static let booleans: Set<String> = ["dry-run", "cropped", "original", "composed", "movie", "overwrite", "youtube", "pretty", "wait", "help"]

    init(_ raw: [String]) throws {
        var index = 0
        while index < raw.count {
            let token = raw[index]
            if token.hasPrefix("--") {
                let body = String(token.dropFirst(2))
                if let equals = body.firstIndex(of: "=") {
                    values[String(body[..<equals])] = String(body[body.index(after: equals)...])
                } else if Self.booleans.contains(body) {
                    flags.insert(body)
                } else {
                    guard index + 1 < raw.count else { throw Failure.usage("--\(body) needs a value.") }
                    values[body] = raw[index + 1]
                    index += 1
                }
            } else if command.isEmpty {
                command = token
            } else {
                positional.append(token)
            }
            index += 1
        }
    }

    func double(_ name: String) throws -> Double? {
        guard let text = values[name] else { return nil }
        guard let value = Double(text), value.isFinite else { throw Failure.usage("--\(name) must be a number.") }
        return value
    }

    func int(_ name: String) throws -> Int? {
        guard let text = values[name] else { return nil }
        guard let value = Int(text) else { throw Failure.usage("--\(name) must be a whole number.") }
        return value
    }
}

enum Failure: Error {
    case usage(String)
    case transport(String, String)
}

// MARK: - Output

var pretty = isatty(STDOUT_FILENO) != 0

func emit(_ object: Any) {
    var options: JSONSerialization.WritingOptions = [.sortedKeys, .withoutEscapingSlashes]
    if pretty { options.insert(.prettyPrinted) }
    if let data = try? JSONSerialization.data(withJSONObject: object, options: options),
       let text = String(data: data, encoding: .utf8) {
        print(text)
    }
}

func exitWithProblem(_ code: String, _ message: String) -> Never {
    emit(["ok": false, "error": ["code": code, "message": message, "retryable": false]])
    FileHandle.standardError.write(Data("yamvideoctl: \(message)\n".utf8))
    exit(2)
}

// MARK: - Finding the app

func bridgeDirectory(_ arguments: Arguments) -> URL {
    if let path = arguments.values["bridge-dir"] { return URL(fileURLWithPath: path, isDirectory: true) }
    return AgentProtocol.discoveryDirectory
}

/// Running instances, newest first. A record whose process is gone is ignored, never
/// trusted: the socket it names is checked again before every connection.
func runningInstances(_ arguments: Arguments) -> [AgentDiscoveryRecord] {
    let directory = bridgeDirectory(arguments)
    let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
    return files.filter { $0.pathExtension == "json" }.compactMap { file in
        guard let data = try? Data(contentsOf: file),
              let record = try? AgentProtocol.decoder.decode(AgentDiscoveryRecord.self, from: data),
              record.protocolVersion == AgentProtocol.version else { return nil }
        let alive = kill(record.processID, 0) == 0 || errno == EPERM
        return alive ? record : nil
    }.sorted { $0.startedAt > $1.startedAt }
}

func chooseInstance(_ arguments: Arguments) throws -> AgentDiscoveryRecord {
    let instances = runningInstances(arguments)
    if let wanted = arguments.values["instance"] {
        guard let match = instances.first(where: { $0.instanceID.uuidString.caseInsensitiveCompare(wanted) == .orderedSame }) else {
            throw Failure.transport("app_not_running", "No running YamVideo has instance \(wanted). See `yamvideoctl sessions`.")
        }
        return match
    }
    guard !instances.isEmpty else {
        throw Failure.transport("app_not_running",
            "YamVideo is not running. Open it first (for example: open -a YamVideo, or open build/YamVideo.app), then try again.")
    }
    guard instances.count == 1 else {
        throw Failure.transport("multiple_instances",
            "\(instances.count) YamVideo instances are running. Pick one with --instance; see `yamvideoctl sessions`.")
    }
    return instances[0]
}

/// Sends one request and returns the parsed response, after checking it came from the
/// instance the discovery record named.
func send(_ request: [String: Any], to record: AgentDiscoveryRecord, timeout: TimeInterval) throws -> [String: Any] {
    let body = try JSONSerialization.data(withJSONObject: request, options: [.sortedKeys])
    let reply: Data
    do { reply = try LocalSocket.request(body, socketPath: record.socketPath, timeout: timeout) }
    catch let error as AgentTransportError { throw Failure.transport(error.code, error.message) }
    guard let response = try? JSONSerialization.jsonObject(with: reply) as? [String: Any] else {
        throw Failure.transport("bad_response", "YamVideo sent something that is not a JSON response.")
    }
    guard (response["instanceID"] as? String)?.caseInsensitiveCompare(record.instanceID.uuidString) == .orderedSame else {
        throw Failure.transport("untrusted_endpoint", "The process answering is not the YamVideo instance the discovery record names.")
    }
    return response
}

// MARK: - Commands

func readJSON(_ path: String) throws -> Any {
    let data: Data
    if path == "-" { data = FileHandle.standardInput.readDataToEndOfFile() }
    else {
        guard let contents = FileManager.default.contents(atPath: (path as NSString).expandingTildeInPath) else {
            throw Failure.usage("Cannot read \(path).")
        }
        data = contents
    }
    do { return try JSONSerialization.jsonObject(with: data) }
    catch { throw Failure.usage("\(path) is not valid JSON: \(error.localizedDescription)") }
}

/// The request for this invocation, or nil for `sessions` (which talks to every instance).
func makeRequest(_ arguments: Arguments) throws -> [String: Any] {
    var request: [String: Any] = ["protocolVersion": AgentProtocol.version]
    let client = arguments.values["client"] ?? ProcessInfo.processInfo.environment["YAMVIDEO_CLIENT"] ?? "yamvideoctl"
    request["client"] = client
    if let session = arguments.values["session"] { request["sessionID"] = session }
    if let project = arguments.values["project"] { request["projectID"] = project }
    if let revision = try arguments.int("revision") { request["expectedRevision"] = revision }

    func requireAddress() throws {
        guard request["sessionID"] != nil, request["projectID"] != nil, request["expectedRevision"] != nil else {
            throw Failure.usage("\(arguments.command) changes the project, so it needs --session, --project and --revision "
                + "from `yamvideoctl state`. The edit is checked against that revision.")
        }
    }
    func requireSession() throws {
        guard request["sessionID"] != nil, request["projectID"] != nil else {
            throw Failure.usage("\(arguments.command) needs --session and --project from `yamvideoctl state`.")
        }
    }
    func value(_ name: String) throws -> String {
        guard let value = arguments.values[name] else { throw Failure.usage("\(arguments.command) needs --\(name).") }
        return value
    }
    func job() throws -> String {
        guard let id = arguments.values["job"] ?? arguments.positional.first else { throw Failure.usage("\(arguments.command) needs a job ID.") }
        return id
    }

    switch arguments.command {
    case "catalog":
        request["method"] = "catalog"
    case "state":
        request["method"] = "state"
    case "events":
        request["method"] = "events"
        if let after = try arguments.int("after") { request["after"] = after }
        if let limit = try arguments.int("limit") { request["limit"] = limit }
    case "apply":
        request["method"] = "apply"
        let file = try readJSON(try value("file"))
        if let commands = file as? [Any] {
            request["commands"] = commands
        } else if let object = file as? [String: Any] {
            for key in ["commands", "sessionID", "projectID", "expectedRevision", "label", "dryRun"] where request[key] == nil {
                if let found = object[key] { request[key] = found }
            }
        } else {
            throw Failure.usage("The edits file must be a list of commands or an object with \"commands\".")
        }
        if let label = arguments.values["label"] { request["label"] = label }
        if arguments.flags.contains("dry-run") { request["dryRun"] = true }
        try requireAddress()
    case "undo", "redo":
        request["method"] = arguments.command
        request["transactionID"] = try value("transaction")
        try requireAddress()
    case "save":
        request["method"] = "save"
        if let path = arguments.values["path"] { request["path"] = path }
        if arguments.flags.contains("overwrite") { request["overwrite"] = true }
        try requireAddress()
    case "export":
        request["method"] = "export"
        request["path"] = try value("path")
        if arguments.flags.contains("movie") { request["scope"] = "movie" }
        else { request["scope"] = "recording"; request["clip"] = try value("clip") }
        if arguments.flags.contains("overwrite") { request["overwrite"] = true }
        if arguments.flags.contains("youtube") { request["youtube"] = true }
        try requireAddress()
    case "analyze":
        request["method"] = "analyze"
        request["kind"] = try value("kind")
        request["clip"] = try value("clip")
        for name in ["threshold", "minimum", "padding"] { if let number = try arguments.double(name) { request[name] = number } }
        try requireSession()
    case "preview":
        request["method"] = "preview"
        guard let time = try arguments.double("time") else { throw Failure.usage("preview needs --time.") }
        request["time"] = time
        if arguments.flags.contains("movie") { request["timeSpace"] = "movie" } else { request["clip"] = try value("clip") }
        if arguments.flags.contains("cropped") { request["cropped"] = true }
        if arguments.flags.contains("original") { request["original"] = true }
        if arguments.flags.contains("composed") { request["composed"] = true }
    case "job":
        request["method"] = "job"; request["job"] = try job()
    case "cancel":
        request["method"] = "cancel"; request["job"] = try job()
    case "reveal":
        request["method"] = "reveal"
        if let clip = arguments.values["clip"] { request["clip"] = clip }
        if let section = arguments.values["section"] { request["section"] = section }
        if let zoom = arguments.values["zoom"] { request["zoom"] = zoom }
        if let effect = arguments.values["effect"] { request["effect"] = effect }
        if let marker = arguments.values["marker"] { request["marker"] = marker }
        if let graphic = arguments.values["graphic"] { request["graphic"] = graphic }
        if let time = try arguments.double("time") { request["time"] = time }
        if arguments.flags.contains("movie") { request["timeSpace"] = "movie" }
    case "request":
        guard let raw = try readJSON(try value("file")) as? [String: Any], raw["method"] is String else {
            throw Failure.usage("The request file must be an object with a \"method\".")
        }
        for (key, value) in raw { request[key] = value }
    default:
        throw Failure.usage("Unknown command \"\(arguments.command)\". Run yamvideoctl --help.")
    }
    let edits: Set<String> = ["apply", "undo", "redo", "save", "export", "analyze", "cancel"]
    if edits.contains(request["method"] as? String ?? ""), request["requestID"] == nil {
        request["requestID"] = arguments.values["request-id"] ?? UUID().uuidString
    }
    return request
}

func run() -> Int32 {
    let arguments: Arguments
    do { arguments = try Arguments(Array(CommandLine.arguments.dropFirst())) }
    catch Failure.usage(let message) { exitWithProblem("usage", message) }
    catch { exitWithProblem("usage", "\(error)") }
    if arguments.flags.contains("pretty") { pretty = true }
    if arguments.command.isEmpty || arguments.command == "help" || arguments.flags.contains("help") {
        print(usage); return arguments.command.isEmpty && !arguments.flags.contains("help") ? 2 : 0
    }
    let timeout = (try? arguments.double("timeout")) ?? 120

    do {
        if arguments.command == "sessions" {
            var sessions: [Any] = []
            for record in runningInstances(arguments) {
                do {
                    let response = try send(["protocolVersion": AgentProtocol.version, "method": "sessions"], to: record, timeout: timeout)
                    sessions += ((response["result"] as? [String: Any])?["sessions"] as? [Any]) ?? []
                } catch Failure.transport(let code, let message) {
                    sessions.append(["instanceID": record.instanceID.uuidString, "error": ["code": code, "message": message]])
                }
            }
            emit(["ok": true, "result": ["sessions": sessions]])
            return 0
        }
        let request = try makeRequest(arguments)
        let record = try chooseInstance(arguments)
        var response = try send(request, to: record, timeout: timeout)
        // --wait polls a job until it finishes.
        if arguments.flags.contains("wait"), request["method"] as? String == "job" {
            while response["ok"] as? Bool == true,
                  ((response["result"] as? [String: Any])?["status"] as? String) == "running" {
                usleep(400_000)
                response = try send(request, to: record, timeout: timeout)
            }
        }
        emit(response)
        if response["ok"] as? Bool != true, let error = response["error"] as? [String: Any], let message = error["message"] as? String {
            FileHandle.standardError.write(Data("yamvideoctl: \(message)\n".utf8))
        }
        return response["ok"] as? Bool == true ? 0 : 1
    } catch Failure.usage(let message) {
        exitWithProblem("usage", message)
    } catch Failure.transport(let code, let message) {
        exitWithProblem(code, message)
    } catch {
        exitWithProblem("failed", error.localizedDescription)
    }
}

exit(run())
