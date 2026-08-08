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
    /// when it is supplied, stdout is not captured in the result.
    static func run(
        _ executable: String,
        _ arguments: [String],
        onStdoutLine: (@Sendable (String) -> Void)? = nil
    ) async throws -> ShellResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        let outBox = DataBox()
        let errBox = DataBox()
        let waiter = ProcessWaiter()
        process.terminationHandler = { _ in waiter.finish() }

        if let onStdoutLine {
            let splitter = LineSplitter()
            outPipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if chunk.isEmpty {
                    handle.readabilityHandler = nil
                    return
                }
                splitter.feed(chunk, onStdoutLine)
            }
        }

        // Drain on background threads so a full pipe buffer can never deadlock the process.
        let group = DispatchGroup()
        if onStdoutLine == nil {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                outBox.append(outPipe.fileHandleForReading.readDataToEndOfFile())
                group.leave()
            }
        }
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            errBox.append(errPipe.fileHandleForReading.readDataToEndOfFile())
            group.leave()
        }

        try process.run()

        await withTaskCancellationHandler {
            await waiter.wait()
        } onCancel: {
            process.terminate()
        }

        outPipe.fileHandleForReading.readabilityHandler = nil
        // Let the drain threads finish without blocking this task's thread.
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            group.notify(queue: .global(qos: .userInitiated)) { cont.resume() }
        }

        return ShellResult(status: process.terminationStatus, stdout: outBox.value, stderr: errBox.value)
    }
}
