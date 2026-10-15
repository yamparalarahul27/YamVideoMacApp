import Foundation

/// Waits for a `Process` to exit without racing the termination handler.
private final class ProcessWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private var continuation: CheckedContinuation<Void, Never>?

    func finish() {
        lock.lock()
        let cont = continuation
        continuation = nil
        finished = true
        lock.unlock()
        cont?.resume()
    }

    func wait() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            lock.lock()
            if finished {
                lock.unlock()
                cont.resume()
            } else {
                continuation = cont
                lock.unlock()
            }
        }
    }
}

private final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.lock(); data.append(chunk); lock.unlock()
    }

    var value: Data {
        lock.lock(); defer { lock.unlock() }
        return data
    }
}

/// Splits an incoming byte stream into lines (ffmpeg's `-progress` output uses both \n and \r).
private final class LineSplitter: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()

    func feed(_ chunk: Data, _ onLine: (String) -> Void) {
        lock.lock()
        buffer.append(chunk)
        var lines: [String] = []
        while let idx = buffer.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
            let lineData = buffer[buffer.startIndex..<idx]
            buffer.removeSubrange(buffer.startIndex...idx)
            if let s = String(data: lineData, encoding: .utf8), !s.isEmpty { lines.append(s) }
        }
        lock.unlock()
        lines.forEach(onLine)
    }
}

struct ShellResult {
    var status: Int32
    var stdout: Data
    var stderr: Data
    var stderrText: String { String(data: stderr, encoding: .utf8) ?? "" }
    var stdoutText: String { String(data: stdout, encoding: .utf8) ?? "" }
}

enum Shell {
    /// Runs a command to completion, capturing both streams.
    /// `onStdoutLine` receives stdout line-by-line as it arrives (used for ffmpeg progress);
    /// when it is supplied, stdout is not captured in the result. `onStderrLine` sees
    /// stderr the same way, which is still captured.
    static func run(
        _ executable: String,
        _ arguments: [String],
        environment: [String: String]? = nil,
        onStdoutLine: (@Sendable (String) -> Void)? = nil,
        onStderrLine: (@Sendable (String) -> Void)? = nil
    ) async throws -> ShellResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment { process.environment = environment }
        process.standardInput = FileHandle.nullDevice

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        let outBox = DataBox()
        let errBox = DataBox()
        let waiter = ProcessWaiter()
        process.terminationHandler = { _ in waiter.finish() }

        try Task.checkCancellation()
        try process.run()
        // Drain on background threads so a full pipe buffer can never deadlock the process.
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            defer { group.leave() }
            if let onStdoutLine {
                let splitter = LineSplitter()
                while let chunk = try? outPipe.fileHandleForReading.read(upToCount: 65536), !chunk.isEmpty {
                    splitter.feed(chunk, onStdoutLine)
                }
                splitter.feed(Data([10]), onStdoutLine)
            } else {
                outBox.append(outPipe.fileHandleForReading.readDataToEndOfFile())
            }
        }
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            defer { group.leave() }
            if let onStderrLine {
                let splitter = LineSplitter()
                while let chunk = try? errPipe.fileHandleForReading.read(upToCount: 65536), !chunk.isEmpty {
                    errBox.append(chunk)
                    splitter.feed(chunk, onStderrLine)
                }
                splitter.feed(Data([10]), onStderrLine)
            } else {
                errBox.append(errPipe.fileHandleForReading.readDataToEndOfFile())
            }
        }

        await withTaskCancellationHandler {
            await waiter.wait()
        } onCancel: {
            process.terminate()
        }

        // Let the drain threads finish without blocking this task's thread.
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            group.notify(queue: .global(qos: .userInitiated)) { cont.resume() }
        }

        return ShellResult(status: process.terminationStatus, stdout: outBox.value, stderr: errBox.value)
    }
}
