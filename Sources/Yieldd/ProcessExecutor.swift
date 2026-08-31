import Dispatch
import Darwin
import Foundation

struct ProcessRequest: Equatable, Sendable {
    let executableURL: URL
    let arguments: [String]
    // The executor writes this complete payload once. Keep it bounded; this is not a streaming API.
    let standardInput: Data?
    let timeout: TimeInterval?
    let cancellable: Bool

    init(
        executableURL: URL,
        arguments: [String],
        standardInput: Data? = nil,
        timeout: TimeInterval? = nil,
        cancellable: Bool = true
    ) {
        if let timeout {
            precondition(timeout.isFinite && timeout > 0)
        }
        self.executableURL = executableURL
        self.arguments = arguments
        self.standardInput = standardInput
        self.timeout = timeout
        self.cancellable = cancellable
    }
}

enum ProcessTerminationReason: Equatable, Sendable {
    case exit
    case uncaughtSignal
}

struct ProcessResult: Equatable, Sendable {
    let stdout: Data
    let stderr: Data
    let terminationReason: ProcessTerminationReason
    let terminationStatus: Int32

    var stdoutText: String {
        String(decoding: stdout, as: UTF8.self)
    }

    var stderrText: String {
        String(decoding: stderr, as: UTF8.self)
    }

    @discardableResult
    func requireSuccess(for request: ProcessRequest) throws -> ProcessResult {
        switch terminationReason {
        case .exit where terminationStatus == 0:
            return self
        case .exit:
            throw ProcessExecutionError.nonZeroExit(request: request, result: self)
        case .uncaughtSignal:
            throw ProcessExecutionError.terminatedBySignal(request: request, result: self)
        }
    }
}

enum CapturedStream: String, Hashable, Sendable {
    case stdout
    case stderr
}

enum ProcessExecutionError: Error {
    case launchFailed(request: ProcessRequest, underlying: any Error)
    case inputWriteFailed(request: ProcessRequest, underlying: any Error)
    case outputReadFailed(request: ProcessRequest, stream: CapturedStream, underlying: any Error)
    case cancelled(request: ProcessRequest, result: ProcessResult, underlying: any Error)
    case timedOut(request: ProcessRequest, result: ProcessResult)
    case nonZeroExit(request: ProcessRequest, result: ProcessResult)
    case terminatedBySignal(request: ProcessRequest, result: ProcessResult)
}

extension ProcessExecutionError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case let .launchFailed(request, underlying):
            "Failed to launch \(request.executableURL.path): \(underlying.localizedDescription)"
        case let .inputWriteFailed(request, underlying):
            "Failed to write stdin to \(request.executableURL.path): \(underlying.localizedDescription)"
        case let .outputReadFailed(request, stream, underlying):
            "Failed to read \(stream.rawValue) from \(request.executableURL.path): \(underlying.localizedDescription)"
        case let .cancelled(request, result, underlying):
            processFailureDescription(
                executableURL: request.executableURL,
                reason: "was cancelled: \(underlying.localizedDescription)",
                stderr: result.stderrText
            )
        case let .timedOut(request, result):
            processFailureDescription(
                executableURL: request.executableURL,
                reason: "timed out after \(request.timeout ?? 0) seconds",
                stderr: result.stderrText
            )
        case let .nonZeroExit(request, result):
            processFailureDescription(
                executableURL: request.executableURL,
                reason: "exited with status \(result.terminationStatus)",
                stderr: result.stderrText
            )
        case let .terminatedBySignal(request, result):
            processFailureDescription(
                executableURL: request.executableURL,
                reason: "was terminated by signal \(result.terminationStatus)",
                stderr: result.stderrText
            )
        }
    }

    private func processFailureDescription(executableURL: URL, reason: String, stderr: String) -> String {
        let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !detail.isEmpty else {
            return "Process \(executableURL.path) \(reason)."
        }
        return "Process \(executableURL.path) \(reason): \(detail)"
    }
}

protocol ProcessExecuting {
    func execute(_ request: ProcessRequest) throws -> ProcessResult
}

struct ProcessExecutor: ProcessExecuting {
    private let terminationGracePeriod: TimeInterval
    private let cancellationPollInterval: TimeInterval
    private let checkCancellation: (() throws -> Void)?

    init(
        terminationGracePeriod: TimeInterval = 2,
        cancellationPollInterval: TimeInterval = 0.1,
        checkCancellation: (() throws -> Void)? = nil
    ) {
        precondition(terminationGracePeriod.isFinite && terminationGracePeriod >= 0)
        precondition(cancellationPollInterval.isFinite && cancellationPollInterval > 0)
        self.terminationGracePeriod = terminationGracePeriod
        self.cancellationPollInterval = cancellationPollInterval
        self.checkCancellation = checkCancellation
    }

    func execute(_ request: ProcessRequest) throws -> ProcessResult {
        let process = Process()
        let stdinPipe = request.standardInput.map { _ in Pipe() }
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        process.executableURL = request.executableURL
        process.arguments = request.arguments
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        let termination = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            termination.signal()
        }

        if let stdinPipe {
            let descriptor = stdinPipe.fileHandleForWriting.fileDescriptor
            guard fcntl(descriptor, F_SETNOSIGPIPE, 1) != -1 else {
                let errorCode = POSIXErrorCode(rawValue: errno) ?? .EIO
                throw ProcessExecutionError.inputWriteFailed(
                    request: request,
                    underlying: POSIXError(errorCode)
                )
            }
        }

        do {
            try process.run()
        } catch {
            throw ProcessExecutionError.launchFailed(request: request, underlying: error)
        }
        let timeoutDeadline = request.timeout.map {
            DispatchTime.now() + dispatchInterval($0)
        }

        let stdoutReader = PipeReader(fileHandle: stdoutPipe.fileHandleForReading)
        let stderrReader = PipeReader(fileHandle: stderrPipe.fileHandleForReading)
        let readers = [(CapturedStream.stdout, stdoutReader), (.stderr, stderrReader)]
        let inputWriter = request.standardInput.flatMap { standardInput in
            stdinPipe.map { pipe in
                PipeWriter(
                    fileHandle: pipe.fileHandleForWriting,
                    data: standardInput
                )
            }
        }
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "dev.yieldd.process-io", attributes: .concurrent)

        for (_, reader) in readers {
            group.enter()
            queue.async {
                reader.readToEnd()
                group.leave()
            }
        }

        if let inputWriter {
            group.enter()
            queue.async {
                inputWriter.write()
                group.leave()
            }
        }

        var waitOutcome = waitForExit(
            process,
            deadline: timeoutDeadline,
            cancellable: request.cancellable,
            termination: termination
        )
        if case .exited = waitOutcome {
            waitOutcome = waitForIO(
                group,
                deadline: timeoutDeadline,
                cancellable: request.cancellable
            )
        }
        switch waitOutcome {
        case .timedOut, .cancelled:
            // Descendants can keep inherited descriptors open after the launched process exits.
            // Close our endpoints before waiting for the I/O tasks so cancellation stays bounded.
            for (_, reader) in readers {
                reader.cancel()
            }
            inputWriter?.cancel()
            group.wait()
        case .exited:
            break
        }

        var output: [CapturedStream: Data] = [:]
        for (stream, reader) in readers {
            do {
                output[stream] = try reader.result().get()
            } catch {
                throw ProcessExecutionError.outputReadFailed(
                    request: request,
                    stream: stream,
                    underlying: error
                )
            }
        }

        let terminationReason: ProcessTerminationReason = switch process.terminationReason {
        case .exit:
            .exit
        case .uncaughtSignal:
            .uncaughtSignal
        @unknown default:
            .uncaughtSignal
        }

        let result = ProcessResult(
            stdout: output[.stdout] ?? Data(),
            stderr: output[.stderr] ?? Data(),
            terminationReason: terminationReason,
            terminationStatus: process.terminationStatus
        )

        switch waitOutcome {
        case .timedOut:
            throw ProcessExecutionError.timedOut(request: request, result: result)
        case let .cancelled(error):
            throw ProcessExecutionError.cancelled(
                request: request,
                result: result,
                underlying: error
            )
        case .exited:
            break
        }

        if let inputWriter, case let .failure(error) = inputWriter.result(),
           result.terminationReason == .exit, result.terminationStatus == 0,
           !isBrokenPipe(error) {
            throw ProcessExecutionError.inputWriteFailed(
                request: request,
                underlying: error
            )
        }

        return result
    }

    private func waitForExit(
        _ process: Process,
        deadline: DispatchTime?,
        cancellable: Bool,
        termination: DispatchSemaphore
    ) -> ProcessWaitOutcome {
        guard cancellable, checkCancellation != nil else {
            guard let deadline else {
                process.waitUntilExit()
                return .exited
            }

            guard termination.wait(timeout: deadline) == .timedOut else {
                process.waitUntilExit()
                return .exited
            }

            terminate(process, termination: termination)
            return .timedOut
        }

        while true {
            do {
                try checkCancellation?()
            } catch {
                terminate(process, termination: termination)
                return .cancelled(error)
            }

            let waitDeadline = nextPollDeadline(timeoutDeadline: deadline)
            if termination.wait(timeout: waitDeadline) == .success {
                process.waitUntilExit()
                do {
                    try checkCancellation?()
                    return .exited
                } catch {
                    return .cancelled(error)
                }
            }

            if let deadline, DispatchTime.now().uptimeNanoseconds >= deadline.uptimeNanoseconds {
                terminate(process, termination: termination)
                return .timedOut
            }
        }
    }

    private func waitForIO(
        _ group: DispatchGroup,
        deadline: DispatchTime?,
        cancellable: Bool
    ) -> ProcessWaitOutcome {
        guard cancellable, checkCancellation != nil else {
            guard let deadline else {
                group.wait()
                return .exited
            }
            return group.wait(timeout: deadline) == .success ? .exited : .timedOut
        }

        while true {
            do {
                try checkCancellation?()
            } catch {
                return .cancelled(error)
            }

            let waitDeadline = nextPollDeadline(timeoutDeadline: deadline)
            if group.wait(timeout: waitDeadline) == .success {
                do {
                    try checkCancellation?()
                    return .exited
                } catch {
                    return .cancelled(error)
                }
            }

            if let deadline, DispatchTime.now().uptimeNanoseconds >= deadline.uptimeNanoseconds {
                return .timedOut
            }
        }
    }

    private func terminate(
        _ process: Process,
        termination: DispatchSemaphore
    ) {
        if termination.wait(timeout: .now()) == .success {
            process.waitUntilExit()
            return
        }

        process.terminate()
        if termination.wait(
            timeout: .now() + dispatchInterval(terminationGracePeriod)
        ) == .timedOut {
            Darwin.kill(process.processIdentifier, SIGKILL)
        }
        process.waitUntilExit()
    }

    private func nextPollDeadline(timeoutDeadline: DispatchTime?) -> DispatchTime {
        let pollDeadline = DispatchTime.now() + dispatchInterval(cancellationPollInterval)
        guard let timeoutDeadline,
              timeoutDeadline.uptimeNanoseconds < pollDeadline.uptimeNanoseconds else {
            return pollDeadline
        }
        return timeoutDeadline
    }

    private func dispatchInterval(_ interval: TimeInterval) -> DispatchTimeInterval {
        .milliseconds(Int((interval * 1_000).rounded(.up)))
    }

    private func isBrokenPipe(_ error: any Error) -> Bool {
        var current: NSError? = error as NSError
        while let error = current {
            if error.domain == NSPOSIXErrorDomain, error.code == Int(EPIPE) {
                return true
            }
            current = error.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return false
    }
}

private enum ProcessWaitOutcome {
    case exited
    case timedOut
    case cancelled(any Error)
}

// Access to the result is serialized, and the file handle is read by one task.
private final class PipeReader: @unchecked Sendable {
    private let fileHandle: FileHandle
    private let lock = NSLock()
    private var storedResult: Result<Data, any Error>?

    init(fileHandle: FileHandle) {
        self.fileHandle = fileHandle
    }

    func readToEnd() {
        let result: Result<Data, any Error>
        do {
            result = .success(try fileHandle.readToEnd() ?? Data())
        } catch {
            result = .failure(error)
        }

        lock.lock()
        storedResult = result
        lock.unlock()
    }

    func result() -> Result<Data, any Error> {
        lock.lock()
        defer { lock.unlock() }

        guard let storedResult else {
            preconditionFailure("Pipe result read before the reader completed")
        }
        return storedResult
    }

    func cancel() {
        try? fileHandle.close()
    }
}

// Access to the result is serialized, and the file handle is written by one task.
private final class PipeWriter: @unchecked Sendable {
    private let fileHandle: FileHandle
    private let data: Data
    private let lock = NSLock()
    private var storedResult: Result<Void, any Error>?

    init(fileHandle: FileHandle, data: Data) {
        self.fileHandle = fileHandle
        self.data = data
    }

    func write() {
        let result: Result<Void, any Error>
        do {
            try fileHandle.write(contentsOf: data)
            try fileHandle.close()
            result = .success(())
        } catch {
            try? fileHandle.close()
            result = .failure(error)
        }

        lock.lock()
        storedResult = result
        lock.unlock()
    }

    func result() -> Result<Void, any Error> {
        lock.lock()
        defer { lock.unlock() }

        guard let storedResult else {
            preconditionFailure("Pipe result read before the writer completed")
        }
        return storedResult
    }

    func cancel() {
        try? fileHandle.close()
    }
}
