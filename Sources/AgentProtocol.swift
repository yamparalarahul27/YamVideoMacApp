import Darwin
import Foundation

// The wire contract between YamVideo and local clients such as `yamvideoctl`.
//
// Foundation-only on purpose: the command-line tool compiles this file and nothing else
// from the app, so it can never reach the app's model or windows. Requests and
// responses are single lines of UTF-8 JSON over a private Unix-domain socket.

enum AgentProtocol {
    static let version = 1
    /// One request line, including its commands.
    static let maxRequestBytes = 1 << 20
    static let maxCommands = 100
    static let eventPageLimit = 100
    /// Request IDs remembered per session for idempotent retries. Past this a client must
    /// start a new session rather than risk an old ID being forgotten and applied twice.
    static let maxRequestIDs = 10_000

    /// Where running instances advertise their socket. `YAMVIDEO_AGENT_BRIDGE_DIR`
    /// overrides it, so tests never touch the real one.
    static var discoveryDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["YAMVIDEO_AGENT_BRIDGE_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("YamVideo", isDirectory: true)
            .appendingPathComponent("AgentBridge", isDirectory: true)
    }

    /// A complete error response, for failures that happen before a request is understood.
    static func errorLine(code: String, message: String, instanceID: UUID?) -> Data {
        let body = AgentErrorBody(code: code, message: message, retryable: false, currentRevision: nil)
        let envelope = AgentResponseEnvelope<AgentEmpty>(instanceID: instanceID, ok: false, result: nil, error: body)
        return (try? AgentProtocol.encoder.encode(envelope)) ?? Data(#"{"ok":false}"#.utf8)
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

/// Written by a running app so clients can find it. It names a socket; it never
/// authorizes anything by itself — a client still checks the socket's owner and mode,
/// and that the instance answering is the one the record names.
struct AgentDiscoveryRecord: Codable, Equatable {
    var protocolVersion: Int
    var instanceID: UUID
    var processID: Int32
    var socketPath: String
    var startedAt: Date
}

struct AgentErrorBody: Codable, Equatable {
    var code: String
    var message: String
    var retryable: Bool
    var currentRevision: Int?
}

struct AgentEmpty: Codable, Equatable {}

struct AgentResponseEnvelope<Result: Encodable>: Encodable {
    var protocolVersion = AgentProtocol.version
    var instanceID: UUID?
    var ok: Bool
    var result: Result?
    var error: AgentErrorBody?
}

/// Arbitrary JSON, for the parts of the protocol that pass values through: a settings
/// patch, a job's result.
enum JSONValue: Codable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else { self = .object(try container.decode([String: JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    /// Any `Encodable` value as JSON, via its own encoding.
    static func from<T: Encodable>(_ value: T) throws -> JSONValue {
        try AgentProtocol.decoder.decode(JSONValue.self, from: AgentProtocol.encoder.encode(value))
    }
}

struct AgentTransportError: Error, LocalizedError {
    var code: String
    var message: String
    var errorDescription: String? { message }
}

/// Minimal POSIX plumbing for the socket, shared by the app's listener and its clients.
enum LocalSocket {
    /// `sun_path` holds 104 bytes on macOS, including the terminating NUL.
    static let maxPathLength = MemoryLayout.size(ofValue: sockaddr_un().sun_path) - 1

    static func address(_ path: String) throws -> sockaddr_un {
        let bytes = Array(path.utf8)
        guard !bytes.isEmpty, bytes.count <= maxPathLength else {
            throw AgentTransportError(code: "socket_path_too_long",
                                      message: "The socket path is longer than the \(maxPathLength)-byte limit.")
        }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        return address
    }

    /// Suppress SIGPIPE: writing to a peer that went away must be an error, not a crash.
    static func configure(_ fd: Int32, timeout: TimeInterval) {
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var time = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - floor(timeout)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &time, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &time, socklen_t(MemoryLayout<timeval>.size))
    }

    /// Refuses anything but a socket owned by this user, in a directory only this user
    /// can enter — never a symlink to somebody else's endpoint.
    static func verifyEndpoint(_ path: String) throws {
        var socketStat = stat(), directoryStat = stat()
        guard lstat(path, &socketStat) == 0 else {
            throw AgentTransportError(code: "app_not_running", message: "No YamVideo socket at \(path).")
        }
        let directory = (path as NSString).deletingLastPathComponent
        guard (socketStat.st_mode & S_IFMT) == S_IFSOCK, socketStat.st_uid == getuid(),
              lstat(directory, &directoryStat) == 0, (directoryStat.st_mode & S_IFMT) == S_IFDIR,
              directoryStat.st_uid == getuid(), directoryStat.st_mode & 0o077 == 0 else {
            throw AgentTransportError(code: "untrusted_endpoint",
                                      message: "Refusing \(path): it is not a private socket owned by you.")
        }
    }

    static func connect(to path: String, timeout: TimeInterval) throws -> Int32 {
        try verifyEndpoint(path)
        var address = try address(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw AgentTransportError(code: "socket_failed", message: String(cString: strerror(errno))) }
        configure(fd, timeout: timeout)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            let reason = String(cString: strerror(errno))
            close(fd)
            throw AgentTransportError(code: "app_not_running", message: "Could not connect to YamVideo: \(reason).")
        }
        // The listener must be this user too, not just the file.
        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else {
            close(fd)
            throw AgentTransportError(code: "untrusted_endpoint", message: "The process behind that socket is not yours.")
        }
        return fd
    }

    static func writeLine(_ data: Data, to fd: Int32) throws {
        var line = data
        line.append(0x0A)
        try line.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw AgentTransportError(code: "write_failed", message: String(cString: strerror(errno)))
                }
                offset += written
            }
        }
    }

    /// Reads up to the next newline. `pending` carries bytes received past it.
    static func readLine(from fd: Int32, pending: inout Data, limit: Int) throws -> Data? {
        var chunk = [UInt8](repeating: 0, count: 65_536)
        while true {
            if let newline = pending.firstIndex(of: 0x0A) {
                let line = pending[pending.startIndex..<newline]
                // Checked here too: the newline can arrive in the same read that overflows.
                guard line.count <= limit else {
                    throw AgentTransportError(code: "request_too_large", message: "A message may be at most \(limit) bytes.")
                }
                pending.removeSubrange(pending.startIndex...newline)
                return Data(line)
            }
            guard pending.count <= limit else {
                throw AgentTransportError(code: "request_too_large",
                                          message: "A message may be at most \(limit) bytes.")
            }
            let count = read(fd, &chunk, chunk.count)
            if count == 0 { return nil }
            if count < 0 {
                if errno == EINTR { continue }
                throw AgentTransportError(code: errno == EAGAIN ? "timeout" : "read_failed",
                                          message: errno == EAGAIN ? "Timed out waiting for YamVideo." : String(cString: strerror(errno)))
            }
            pending.append(contentsOf: chunk[0..<count])
        }
    }

    /// One request, one response, one connection.
    static func request(_ data: Data, socketPath: String, timeout: TimeInterval = 120) throws -> Data {
        let fd = try connect(to: socketPath, timeout: timeout)
        defer { close(fd) }
        try writeLine(data, to: fd)
        var pending = Data()
        guard let response = try readLine(from: fd, pending: &pending, limit: 64 << 20) else {
            throw AgentTransportError(code: "connection_closed", message: "YamVideo closed the connection without answering.")
        }
        return response
    }
}
