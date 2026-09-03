import Foundation
import ServiceManagement

private let agentPlistName = "dev.yieldd.agent.plist"

struct LocalAgentService {
    let status: () -> SMAppService.Status
    let register: () throws -> Void
    let unregister: () async throws -> Void
}

func installAgent(
    configuration: AgentConfiguration,
    store: AgentConfigurationStore,
    service: LocalAgentService
) throws {
    switch service.status() {
    case .enabled, .requiresApproval:
        do {
            guard try store.load() == configuration else {
                throw AgentError.configurationChanged
            }
        } catch AgentConfigurationError.missing,
                AgentConfigurationError.invalidContents {
            try store.save(configuration)
        }
    case .notRegistered:
        try store.save(configuration)
        do {
            try service.register()
        } catch {
            // Registration reports denied approval as an error. Re-reading the service state
            // distinguishes that expected result from other registration failures.
            guard service.status() == .requiresApproval else {
                throw error
            }
        }
    case .notFound:
        throw AgentError.serviceNotFound
    @unknown default:
        throw AgentError.unknownStatus
    }
}

func reportAgentStatus(
    store: AgentConfigurationStore,
    service: LocalAgentService,
    output: (String) -> Void
) throws {
    output(registrationStatusDescription(service.status()))

    var configurationError: (any Error)?
    do {
        let configuration = try store.load()
        output("Repositories: \(configuration.repositories.map(\.fullName).joined(separator: ", "))")
        output("container: \(configuration.containerURL.path)")
        output("gh: \(configuration.ghURL.path)")
    } catch AgentConfigurationError.missing {
        output("Configuration: not installed")
    } catch {
        configurationError = error
        output("Configuration: \(describeError(error))")
    }

    let leases = try RunnerLeaseStore(directory: store.directory).load()
    if leases.isEmpty {
        output("Active runner leases: none")
    } else {
        output("Active runner leases:")
        for lease in leases {
            output("- \(lease.runnerID.value) (\(lease.repository.fullName))")
        }
    }

    if let configurationError {
        throw configurationError
    }
}

func uninstallAgent(
    store: AgentConfigurationStore,
    service: LocalAgentService,
    recover: () throws -> Void
) async throws {
    switch service.status() {
    case .enabled, .requiresApproval, .notFound:
        do {
            try await service.unregister()
        } catch where isMissingService(error) {
            break
        }
    case .notRegistered:
        break
    @unknown default:
        throw AgentError.unknownStatus
    }

    try recover()
    try store.remove()
}

func localAgentService(bundle: Bundle = .main) throws -> LocalAgentService {
    let plistURL = bundle.bundleURL
        .appendingPathComponent("Contents/Library/LaunchAgents", isDirectory: true)
        .appendingPathComponent(agentPlistName, isDirectory: false)
    guard bundle.bundleURL.pathExtension == "app",
          FileManager.default.fileExists(atPath: plistURL.path) else {
        throw AgentError.notPackaged
    }

    let service = SMAppService.agent(plistName: agentPlistName)
    return LocalAgentService(
        status: { service.status },
        register: { try service.register() },
        unregister: {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                service.unregister { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: ())
                    }
                }
            }
        }
    )
}

func registrationStatusDescription(_ status: SMAppService.Status) -> String {
    switch status {
    case .notRegistered:
        "Local agent is not registered."
    case .enabled:
        "Local agent is enabled."
    case .requiresApproval:
        "Local agent requires approval in System Settings > General > Login Items & Extensions."
    case .notFound:
        "macOS could not resolve the local agent registration."
    @unknown default:
        "Local agent registration status is unknown."
    }
}

private func isMissingService(_ error: any Error) -> Bool {
    let error = error as NSError
    return error.domain == SMAppServiceErrorDomain
        && error.code == Int(kSMErrorJobNotFound)
}

enum AgentError: Error, Equatable, LocalizedError {
    case notPackaged
    case configurationChanged
    case serviceNotFound
    case unknownStatus

    var errorDescription: String? {
        switch self {
        case .notPackaged:
            "Local agent commands must run from the packaged yieldd application."
        case .configurationChanged:
            "The local agent is already configured differently. Uninstall it before changing its configuration."
        case .serviceNotFound:
            "macOS could not resolve the local agent registration. Uninstall it before installing again."
        case .unknownStatus:
            "macOS returned an unknown local agent registration status."
        }
    }
}
