import Dispatch
import Foundation

struct ProcessRequest: Equatable, Sendable {
    let executableURL: URL
    let arguments: [String]
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
    case outputReadFailed(request: ProcessRequest, stream: CapturedStream, underlying: any Error)
    case nonZeroExit(request: ProcessRequest, result: ProcessResult)
    case terminatedBySignal(request: ProcessRequest, result: ProcessResult)
}

extension ProcessExecutionError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case let .launchFailed(request, underlying):
            "Failed to launch \(request.executableURL.path): \(underlying.localizedDescription)"
        case let .outputReadFailed(request, stream, underlying):
            "Failed to read \(stream.rawValue) from \(request.executableURL.path): \(underlying.localizedDescription)"
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
    func execute(_ request: ProcessRequest) throws -> ProcessResult {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        process.executableURL = request.executableURL
        process.arguments = request.arguments
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            throw ProcessExecutionError.launchFailed(request: request, underlying: error)
        }

        let stdoutReader = PipeReader(fileHandle: stdoutPipe.fileHandleForReading)
        let stderrReader = PipeReader(fileHandle: stderrPipe.fileHandleForReading)
        let readers = [(CapturedStream.stdout, stdoutReader), (.stderr, stderrReader)]
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "dev.yieldd.process-output", attributes: .concurrent)

        for (_, reader) in readers {
            group.enter()
            queue.async {
                reader.readToEnd()
                group.leave()
            }
        }

        process.waitUntilExit()
        group.wait()

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

        return ProcessResult(
            stdout: output[.stdout] ?? Data(),
            stderr: output[.stderr] ?? Data(),
            terminationReason: terminationReason,
            terminationStatus: process.terminationStatus
        )
    }
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
}
