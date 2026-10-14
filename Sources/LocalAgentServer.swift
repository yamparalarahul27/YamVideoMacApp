import Darwin
import Foundation

/// The app's end of the local agent bridge: a Unix-domain socket in a private temporary
/// directory, plus a discovery record so `yamvideoctl` can find it.
///
/// Local only, by construction — there is no network listener. The directory is 0700,
/// the socket 0600, and every connection's peer must be this same user. Each request is
/// handed to `handler`, which runs on the main actor, so the document is never touched
/// from these threads.
final class LocalAgentServer: @unchecked Sendable {
    let instanceID: UUID
    private(set) var socketPath: String?
    private(set) var recordURL: URL?
    private var directory: String?
    private var listener: Int32 = -1
    private let lock = NSLock()
    private let handler: @Sendable (Data) async -> Data

    init(instanceID: UUID = UUID(), handler: @escaping @Sendable (Data) async -> Data) {
        self.instanceID = instanceID
        self.handler = handler
    }

    deinit { stop() }

    func start(discoveryDirectory: URL = AgentProtocol.discoveryDirectory) throws {
        // mkdtemp makes the directory 0700 and unguessable. A short name keeps the full
        // socket path inside the 104-byte limit.
        var template = Array((NSTemporaryDirectory() as NSString).appendingPathComponent("yv-XXXXXX").utf8CString)
        guard let made = mkdtemp(&template) else {
            throw AgentTransportError(code: "socket_failed", message: "Could not create a private socket directory.")
        }
        let directory = String(cString: made)
        let path = (directory as NSString).appendingPathComponent("s")
        var address: sockaddr_un
        do { address = try LocalSocket.address(path) } catch { rmdir(directory); throw error }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { rmdir(directory); throw AgentTransportError(code: "socket_failed", message: String(cString: strerror(errno))) }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, chmod(path, 0o600) == 0, listen(fd, 16) == 0 else {
            let reason = String(cString: strerror(errno))
            close(fd); unlink(path); rmdir(directory)
            throw AgentTransportError(code: "socket_failed", message: "Could not listen for local agents: \(reason).")
        }

        lock.lock()
        self.listener = fd; self.socketPath = path; self.directory = directory
        lock.unlock()

        do {
            recordURL = try publishRecord(in: discoveryDirectory, socketPath: path)
        } catch {
            stop(); throw error
        }
        let thread = Thread { [weak self] in self?.acceptLoop(fd) }
        thread.name = "YamVideo agent listener"
        thread.start()
    }

    /// Closes the listener and removes the socket, its directory and the record. Only
    /// what this instance created is removed.
    func stop() {
        lock.lock()
        let fd = listener, path = socketPath, directory = self.directory, record = recordURL
        listener = -1; socketPath = nil; self.directory = nil; recordURL = nil
        lock.unlock()
        if fd >= 0 { shutdown(fd, SHUT_RDWR); close(fd) }
        if let path { unlink(path) }
        if let directory { rmdir(directory) }
        if let record { try? FileManager.default.removeItem(at: record) }
    }

    // MARK: Discovery

    private func publishRecord(in directory: URL, socketPath: String) throws -> URL {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        Self.removeStaleRecords(in: directory)
        let record = AgentDiscoveryRecord(protocolVersion: AgentProtocol.version, instanceID: instanceID,
                                          processID: getpid(), socketPath: socketPath, startedAt: Date())
        let data = try AgentProtocol.encoder.encode(record)
        let destination = directory.appendingPathComponent("\(instanceID.uuidString).json")
        let staging = directory.appendingPathComponent(".\(instanceID.uuidString).tmp")
        // Created 0600 and then renamed into place, so a reader never sees a partial file.
        guard manager.createFile(atPath: staging.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw AgentTransportError(code: "discovery_failed", message: "Could not write the agent discovery record.")
        }
        guard rename(staging.path, destination.path) == 0 else {
            try? manager.removeItem(at: staging)
            throw AgentTransportError(code: "discovery_failed", message: "Could not publish the agent discovery record.")
        }
        return destination
    }

    /// Records left by an instance that is no longer running. Only the record is removed:
    /// a stale record never authorizes deleting or replacing whatever its path points at.
    static func removeStaleRecords(in directory: URL) {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let record = try? AgentProtocol.decoder.decode(AgentDiscoveryRecord.self, from: data) else { continue }
            if kill(record.processID, 0) != 0, errno == ESRCH { try? FileManager.default.removeItem(at: file) }
        }
    }

    // MARK: Connections

    private func acceptLoop(_ fd: Int32) {
        while true {
            let client = accept(fd, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                return // The listener was closed.
            }
            var uid: uid_t = 0, gid: gid_t = 0
            guard getpeereid(client, &uid, &gid) == 0, uid == getuid() else { close(client); continue }
            LocalSocket.configure(client, timeout: 300)
            let thread = Thread { [weak self] in self?.serve(client) }
            thread.name = "YamVideo agent connection"
            thread.start()
        }
    }

    /// Requests on one connection are answered in order. A timeout only closes the
    /// connection: it never cancels an edit that already reached the app.
    private func serve(_ fd: Int32) {
        defer { close(fd) }
        var pending = Data()
        while true {
            let line: Data
            do {
                guard let next = try LocalSocket.readLine(from: fd, pending: &pending, limit: AgentProtocol.maxRequestBytes) else { return }
                line = next
            } catch let error as AgentTransportError {
                if error.code == "request_too_large" {
                    try? LocalSocket.writeLine(AgentProtocol.errorLine(code: error.code, message: error.message,
                                                                       instanceID: instanceID), to: fd)
                }
                return
            } catch { return }
            guard !line.isEmpty else { continue }
            let response = answer(line)
            do { try LocalSocket.writeLine(response, to: fd) } catch { return }
        }
    }

    /// Bridges this connection's thread to the async, main-actor handler.
    private func answer(_ line: Data) -> Data {
        final class Box: @unchecked Sendable { var value = Data() }
        let box = Box(), done = DispatchSemaphore(value: 0)
        let handler = self.handler
        Task {
            box.value = await handler(line)
            done.signal()
        }
        done.wait()
        return box.value
    }
}
