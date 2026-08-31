import ArgumentParser
import Darwin
import Foundation

struct DoctorCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "doctor",
        abstract: "Check whether this Mac can run yieldd machines."
    )

    mutating func run() throws {
        let report = Doctor().run()
        for check in report.checks {
            print(check.formatted)
        }
        try report.requireSuccess()
    }
}

struct Doctor {
    let executor: any ProcessExecuting
    let executableLocator: ExecutableLocator
    let supportsAppleSilicon: () -> Bool

    init(
        executor: any ProcessExecuting = ProcessExecutor(),
        executableLocator: ExecutableLocator = ExecutableLocator(),
        supportsAppleSilicon: @escaping () -> Bool = HostCapabilities.supportsAppleSilicon
    ) {
        self.executor = executor
        self.executableLocator = executableLocator
        self.supportsAppleSilicon = supportsAppleSilicon
    }

    func run() -> DoctorReport {
        var checks = [DoctorCheck(
            name: "Apple Silicon",
            status: supportsAppleSilicon()
                ? .passed("supported")
                : .failed("this host does not report Apple Silicon support")
        )]

        checks.append(contentsOf: containerChecks())
        checks.append(contentsOf: githubChecks())
        return DoctorReport(checks: checks)
    }

    private func containerChecks() -> [DoctorCheck] {
        var checks: [DoctorCheck] = []
        let containerURL: URL
        do {
            containerURL = try executableLocator.locate("container")
            checks.append(DoctorCheck(
                name: "container executable",
                status: .passed(containerURL.path)
            ))
        } catch {
            checks.append(DoctorCheck(
                name: "container executable",
                status: .failed(describe(error))
            ))
            checks.append(DoctorCheck(
                name: "container system",
                status: .skipped("container executable is unavailable")
            ))
            checks.append(DoctorCheck(
                name: "container machine",
                status: .skipped("container executable is unavailable")
            ))
            return checks
        }

        let systemRequest = ProcessRequest(
            executableURL: containerURL,
            arguments: ["system", "status", "--format", "json"]
        )
        do {
            try executor.execute(systemRequest).requireSuccess(for: systemRequest)
            checks.append(DoctorCheck(name: "container system", status: .passed("reachable")))
        } catch {
            checks.append(DoctorCheck(name: "container system", status: .failed(describe(error))))
            checks.append(DoctorCheck(
                name: "container machine",
                status: .skipped("container system is unreachable")
            ))
            return checks
        }

        let machineRequest = ProcessRequest(
            executableURL: containerURL,
            arguments: ["machine", "list", "--quiet"]
        )
        do {
            try executor.execute(machineRequest).requireSuccess(for: machineRequest)
            checks.append(DoctorCheck(name: "container machine", status: .passed("available")))
        } catch {
            checks.append(DoctorCheck(name: "container machine", status: .failed(describe(error))))
        }

        return checks
    }

    private func githubChecks() -> [DoctorCheck] {
        let ghURL: URL
        do {
            ghURL = try executableLocator.locate("gh")
        } catch {
            return [
                DoctorCheck(name: "gh executable", status: .failed(describe(error))),
                DoctorCheck(
                    name: "GitHub authentication",
                    status: .skipped("gh executable is unavailable")
                ),
            ]
        }

        var checks = [DoctorCheck(name: "gh executable", status: .passed(ghURL.path))]
        let request = ProcessRequest(
            executableURL: ghURL,
            arguments: ["auth", "status", "--active", "--hostname", "github.com"]
        )
        do {
            try executor.execute(request).requireSuccess(for: request)
            checks.append(DoctorCheck(name: "GitHub authentication", status: .passed("authenticated")))
        } catch {
            checks.append(DoctorCheck(name: "GitHub authentication", status: .failed(describe(error))))
        }
        return checks
    }

    private func describe(_ error: any Error) -> String {
        if let localizedError = error as? any LocalizedError,
           let description = localizedError.errorDescription {
            return description
        }
        return String(describing: error)
    }
}

struct DoctorReport: Equatable {
    let checks: [DoctorCheck]

    var succeeded: Bool {
        !checks.contains { check in
            if case .failed = check.status {
                return true
            }
            return false
        }
    }

    func requireSuccess() throws {
        guard succeeded else {
            throw DoctorReportError.checksFailed
        }
    }
}

struct DoctorCheck: Equatable {
    let name: String
    let status: DoctorCheckStatus

    var formatted: String {
        switch status {
        case let .passed(detail):
            "[pass] \(name): \(detail)"
        case let .failed(detail):
            "[fail] \(name): \(detail)"
        case let .skipped(detail):
            "[skip] \(name): \(detail)"
        }
    }
}

enum DoctorCheckStatus: Equatable {
    case passed(String)
    case failed(String)
    case skipped(String)
}

enum DoctorReportError: Error, Equatable, LocalizedError {
    case checksFailed

    var errorDescription: String? {
        "One or more doctor checks failed."
    }
}

private enum HostCapabilities {
    static func supportsAppleSilicon() -> Bool {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let status = sysctlbyname("hw.optional.arm64", &value, &size, nil, 0)
        return status == 0 && value == 1
    }
}
