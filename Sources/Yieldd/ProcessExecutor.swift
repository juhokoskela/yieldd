import Dispatch
import Darwin
import Foundation

enum ProcessOutputCapture: Equatable, Sendable {
    case all
    case tail(maxBytes: Int)
}

struct ProcessRequest: Equatable, Sendable {
    let executableURL: URL
    let arguments: [String]
    // The executor writes this complete payload once. Keep it bounded; this is not a streaming API.
    let standardInput: Data?
    let timeout: TimeInterval?
    let outputCapture: ProcessOutputCapture
    let cancellable: Bool

    init(
        executableURL: URL,
        arguments: [String],
        standardInput: Data? = nil,
        timeout: TimeInterval? = nil,
        outputCapture: ProcessOutputCapture = .all,
        cancellable: Bool = true
    ) {
        if let timeout {
            precondition(timeout.isFinite && timeout > 0)
        }
        if case let .tail(maxBytes) = outputCapture {
            precondition(maxBytes > 0)
        }
        self.executableURL = executableURL
        self.arguments = arguments
        self.standardInput = standardInput
        self.timeout = timeout
        self.outputCapture = outputCapture
        self.cancellable = cancellable
    }
}

struct ProcessResult: Equatable, Sendable {
    let stdout: Data
    let stderr: Data
    let terminationReason: Process.TerminationReason
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
        @unknown default:
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
    case waitFailed(request: ProcessRequest, underlying: any Error)
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
        case let .waitFailed(request, underlying):
            "Failed to wait for \(request.executableURL.path): \(underlying.localizedDescription)"
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
        let stdinPipe = request.standardInput.map { _ in Pipe() }
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        let process: SpawnedProcess
        do {
            if let stdinPipe {
                let descriptor = stdinPipe.fileHandleForWriting.fileDescriptor
                guard fcntl(descriptor, F_SETNOSIGPIPE, 1) != -1 else {
                    throw ProcessExecutionError.inputWriteFailed(
                        request: request,
                        underlying: POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                    )
                }
            }

            process = try spawn(
                request,
                stdin: stdinPipe,
                stdout: stdoutPipe,
                stderr: stderrPipe
            )
            try? stdinPipe?.fileHandleForReading.close()
            try? stdoutPipe.fileHandleForWriting.close()
            try? stderrPipe.fileHandleForWriting.close()
        } catch {
            closePipes(stdin: stdinPipe, stdout: stdoutPipe, stderr: stderrPipe)
            if let executionError = error as? ProcessExecutionError {
                throw executionError
            }
            throw ProcessExecutionError.launchFailed(request: request, underlying: error)
        }

        let timeoutDeadline = request.timeout.map(deadline(after:))
        let stdoutReader = PipeReader(
            fileHandle: stdoutPipe.fileHandleForReading,
            capture: request.outputCapture
        )
        let stderrReader = PipeReader(
            fileHandle: stderrPipe.fileHandleForReading,
            capture: request.outputCapture
        )
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

        for (_, reader) in readers {
            group.enter()
            Thread.detachNewThread {
                reader.readToEnd()
                group.leave()
            }
        }

        if let inputWriter {
            group.enter()
            Thread.detachNewThread {
                inputWriter.write()
                group.leave()
            }
        }

        var waitOutcome = waitForCompletion(
            deadline: timeoutDeadline,
            cancellable: request.cancellable,
            wait: { process.wait(timeout: $0) },
            waitIndefinitely: process.waitUntilExit
        )
        if case .exited = waitOutcome {
            waitOutcome = waitForCompletion(
                deadline: timeoutDeadline,
                cancellable: request.cancellable,
                wait: { group.wait(timeout: $0) },
                waitIndefinitely: group.wait
            )
        }
        switch waitOutcome {
        case .timedOut, .cancelled:
            terminate(process)
            for (_, reader) in readers {
                reader.cancel()
            }
            inputWriter?.cancel()
            group.wait()
        case .exited:
            break
        }

        let exit: SpawnedProcessExit
        do {
            exit = try process.result().get()
        } catch {
            throw ProcessExecutionError.waitFailed(request: request, underlying: error)
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

        let result = ProcessResult(
            stdout: output[.stdout] ?? Data(),
            stderr: output[.stderr] ?? Data(),
            terminationReason: exit.reason,
            terminationStatus: exit.status
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

    private func spawn(
        _ request: ProcessRequest,
        stdin: Pipe?,
        stdout: Pipe,
        stderr: Pipe
    ) throws -> SpawnedProcess {
        var fileActions: posix_spawn_file_actions_t?
        try requirePOSIXSuccess(posix_spawn_file_actions_init(&fileActions))
        defer { posix_spawn_file_actions_destroy(&fileActions) }

        if let stdin {
            try requirePOSIXSuccess(posix_spawn_file_actions_adddup2(
                &fileActions,
                stdin.fileHandleForReading.fileDescriptor,
                STDIN_FILENO
            ))
        } else {
            let status = "/dev/null".withCString { path in
                posix_spawn_file_actions_addopen(
                    &fileActions,
                    STDIN_FILENO,
                    path,
                    O_RDONLY,
                    0
                )
            }
            try requirePOSIXSuccess(status)
        }
        try requirePOSIXSuccess(posix_spawn_file_actions_adddup2(
            &fileActions,
            stdout.fileHandleForWriting.fileDescriptor,
            STDOUT_FILENO
        ))
        try requirePOSIXSuccess(posix_spawn_file_actions_adddup2(
            &fileActions,
            stderr.fileHandleForWriting.fileDescriptor,
            STDERR_FILENO
        ))

        let descriptors = [
            stdin?.fileHandleForReading.fileDescriptor,
            stdin?.fileHandleForWriting.fileDescriptor,
            stdout.fileHandleForReading.fileDescriptor,
            stdout.fileHandleForWriting.fileDescriptor,
            stderr.fileHandleForReading.fileDescriptor,
            stderr.fileHandleForWriting.fileDescriptor,
        ].compactMap { $0 }
        for descriptor in Set(descriptors) where descriptor > STDERR_FILENO {
            try requirePOSIXSuccess(posix_spawn_file_actions_addclose(&fileActions, descriptor))
        }

        var attributes: posix_spawnattr_t?
        try requirePOSIXSuccess(posix_spawnattr_init(&attributes))
        defer { posix_spawnattr_destroy(&attributes) }

        // Signal handling in the parent must not leak into commands, and the process group must
        // exist before the executable starts so cancellation cannot race with setpgid.
        var defaultSignals = sigset_t()
        sigemptyset(&defaultSignals)
        sigaddset(&defaultSignals, SIGINT)
        sigaddset(&defaultSignals, SIGTERM)
        try requirePOSIXSuccess(posix_spawnattr_setsigdefault(&attributes, &defaultSignals))
        var signalMask = sigset_t()
        sigemptyset(&signalMask)
        try requirePOSIXSuccess(posix_spawnattr_setsigmask(&attributes, &signalMask))
        try requirePOSIXSuccess(posix_spawnattr_setpgroup(&attributes, 0))
        let flags = Int16(
            POSIX_SPAWN_CLOEXEC_DEFAULT
                | POSIX_SPAWN_SETPGROUP
                | POSIX_SPAWN_SETSIGDEF
                | POSIX_SPAWN_SETSIGMASK
        )
        try requirePOSIXSuccess(posix_spawnattr_setflags(&attributes, flags))

        var arguments: [UnsafeMutablePointer<CChar>?] = []
        defer {
            for case let argument? in arguments {
                free(argument)
            }
        }
        for argument in [request.executableURL.path] + request.arguments {
            guard let copy = argument.withCString({ strdup($0) }) else {
                throw POSIXError(.ENOMEM)
            }
            arguments.append(copy)
        }
        arguments.append(nil)

        var processIdentifier: pid_t = 0
        let status = request.executableURL.path.withCString { executablePath in
            arguments.withUnsafeMutableBufferPointer { arguments in
                posix_spawn(
                    &processIdentifier,
                    executablePath,
                    &fileActions,
                    &attributes,
                    arguments.baseAddress,
                    environ
                )
            }
        }
        try requirePOSIXSuccess(status)
        return SpawnedProcess(processIdentifier: processIdentifier)
    }

    private func waitForCompletion(
        deadline: DispatchTime?,
        cancellable: Bool,
        wait: (DispatchTime) -> DispatchTimeoutResult,
        waitIndefinitely: () -> Void
    ) -> ProcessWaitOutcome {
        guard cancellable, checkCancellation != nil else {
            guard let deadline else {
                waitIndefinitely()
                return .exited
            }
            return wait(deadline) == .success ? .exited : .timedOut
        }

        while true {
            if wait(.now()) == .success {
                return .exited
            }

            do {
                try checkCancellation?()
            } catch {
                return .cancelled(error)
            }

            let waitDeadline = nextPollDeadline(timeoutDeadline: deadline)
            if wait(waitDeadline) == .success {
                return .exited
            }

            if let deadline, DispatchTime.now().uptimeNanoseconds >= deadline.uptimeNanoseconds {
                return .timedOut
            }
        }
    }

    private func terminate(_ process: SpawnedProcess) {
        // Descendants inherit this group unless they deliberately move themselves elsewhere.
        signalProcessGroup(process.processIdentifier, signal: SIGTERM)
        let graceDeadline = deadline(after: terminationGracePeriod)
        let pause = DispatchSemaphore(value: 0)

        while processGroupExists(process.processIdentifier),
              DispatchTime.now().uptimeNanoseconds < graceDeadline.uptimeNanoseconds {
            let waitDeadline = nextPollDeadline(timeoutDeadline: graceDeadline)
            if process.wait(timeout: waitDeadline) == .success,
               processGroupExists(process.processIdentifier) {
                _ = pause.wait(timeout: waitDeadline)
            }
        }

        if processGroupExists(process.processIdentifier) {
            signalProcessGroup(process.processIdentifier, signal: SIGKILL)
        }
        process.waitUntilExit()
    }

    private func signalProcessGroup(_ processGroup: pid_t, signal: Int32) {
        _ = Darwin.kill(-processGroup, signal)
    }

    private func processGroupExists(_ processGroup: pid_t) -> Bool {
        if Darwin.kill(-processGroup, 0) == 0 {
            return true
        }
        return errno == EPERM
    }

    private func nextPollDeadline(timeoutDeadline: DispatchTime?) -> DispatchTime {
        let pollDeadline = deadline(after: cancellationPollInterval)
        guard let timeoutDeadline,
              timeoutDeadline.uptimeNanoseconds < pollDeadline.uptimeNanoseconds else {
            return pollDeadline
        }
        return timeoutDeadline
    }

    private func deadline(after interval: TimeInterval) -> DispatchTime {
        let nanoseconds = (interval * 1_000_000_000).rounded(.up)
        guard nanoseconds.isFinite,
              nanoseconds >= 0,
              nanoseconds < Double(UInt64.max) else {
            return .distantFuture
        }

        let now = DispatchTime.now().uptimeNanoseconds
        let delta = UInt64(nanoseconds)
        guard delta <= UInt64.max - now else {
            return .distantFuture
        }
        return DispatchTime(uptimeNanoseconds: now + delta)
    }

    private func requirePOSIXSuccess(_ status: Int32) throws {
        guard status == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: status) ?? .EIO)
        }
    }

    private func closePipes(stdin: Pipe?, stdout: Pipe, stderr: Pipe) {
        try? stdin?.fileHandleForReading.close()
        try? stdin?.fileHandleForWriting.close()
        try? stdout.fileHandleForReading.close()
        try? stdout.fileHandleForWriting.close()
        try? stderr.fileHandleForReading.close()
        try? stderr.fileHandleForWriting.close()
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

private struct SpawnedProcessExit: Sendable {
    let reason: Process.TerminationReason
    let status: Int32
}

private final class SpawnedProcess: @unchecked Sendable {
    let processIdentifier: pid_t

    private let completion = DispatchGroup()
    private let lock = NSLock()
    private var storedResult: Result<SpawnedProcessExit, any Error>?

    init(processIdentifier: pid_t) {
        self.processIdentifier = processIdentifier
        completion.enter()
        Thread.detachNewThread { [self] in
            let result = Result { try Self.wait(for: processIdentifier) }
            lock.withLock {
                storedResult = result
            }
            completion.leave()
        }
    }

    func wait(timeout: DispatchTime) -> DispatchTimeoutResult {
        completion.wait(timeout: timeout)
    }

    func waitUntilExit() {
        completion.wait()
    }

    func result() -> Result<SpawnedProcessExit, any Error> {
        lock.withLock {
            guard let storedResult else {
                preconditionFailure("Process result read before the process exited")
            }
            return storedResult
        }
    }

    private static func wait(for processIdentifier: pid_t) throws -> SpawnedProcessExit {
        var waitStatus: Int32 = 0
        while true {
            let result = waitpid(processIdentifier, &waitStatus, 0)
            if result == processIdentifier {
                break
            }
            if result == -1, errno == EINTR {
                continue
            }
            let errorCode = POSIXErrorCode(rawValue: errno) ?? .EIO
            throw POSIXError(errorCode)
        }

        // Darwin's WIFEXITED and related macros are not imported into Swift.
        let status = waitStatus & 0o177
        if status == 0 {
            return SpawnedProcessExit(
                reason: .exit,
                status: (waitStatus >> 8) & 0xff
            )
        }
        return SpawnedProcessExit(reason: .uncaughtSignal, status: status)
    }
}

// Access to the result and cancellation state is serialized. One task owns the file handle reads.
private final class PipeReader: @unchecked Sendable {
    private static let chunkSize = 64 * 1_024

    private let fileHandle: FileHandle
    private let capture: ProcessOutputCapture
    private let lock = NSLock()
    private var storedResult: Result<Data, any Error>?
    private var isCancelled = false

    init(fileHandle: FileHandle, capture: ProcessOutputCapture) {
        self.fileHandle = fileHandle
        self.capture = capture
    }

    func readToEnd() {
        var output = CapturedOutput(capture: capture)
        let result: Result<Data, any Error>
        do {
            while let chunk = try autoreleasepool(invoking: {
                try fileHandle.read(upToCount: Self.chunkSize)
            }), !chunk.isEmpty {
                output.append(chunk)
            }
            result = .success(output.data)
        } catch {
            result = lock.withLock {
                isCancelled ? .success(output.data) : .failure(error)
            }
        }
        try? fileHandle.close()

        lock.withLock {
            storedResult = result
        }
    }

    func result() -> Result<Data, any Error> {
        lock.withLock {
            guard let storedResult else {
                preconditionFailure("Pipe result read before the reader completed")
            }
            return storedResult
        }
    }

    func cancel() {
        lock.withLock {
            isCancelled = true
        }
        try? fileHandle.close()
    }
}

private struct CapturedOutput {
    private let maximumBytes: Int?
    private var storage = Data()

    init(capture: ProcessOutputCapture) {
        maximumBytes = switch capture {
        case .all:
            nil
        case let .tail(maxBytes):
            maxBytes
        }
    }

    mutating func append(_ data: Data) {
        storage.append(data)
        guard let maximumBytes,
              storage.count > maximumBytes,
              storage.count - maximumBytes >= maximumBytes else {
            return
        }
        storage = Data(storage.suffix(maximumBytes))
    }

    var data: Data {
        guard let maximumBytes, storage.count > maximumBytes else {
            return storage
        }
        return Data(storage.suffix(maximumBytes))
    }
}

// Access to the result is serialized, and one task owns the file handle writes.
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
        let result = Result<Void, any Error> {
            try fileHandle.write(contentsOf: data)
            try fileHandle.close()
        }
        if case .failure = result {
            try? fileHandle.close()
        }

        lock.withLock {
            storedResult = result
        }
    }

    func result() -> Result<Void, any Error> {
        lock.withLock {
            guard let storedResult else {
                preconditionFailure("Pipe result read before the writer completed")
            }
            return storedResult
        }
    }

    func cancel() {
        try? fileHandle.close()
    }
}
