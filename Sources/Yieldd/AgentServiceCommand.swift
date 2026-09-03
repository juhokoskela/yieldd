import ArgumentParser
import Foundation
import ServiceManagement

private let agentPlistName = "dev.yieldd.agent.plist"

struct AgentServiceCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "service",
        abstract: "Manage the installed local agent.",
        subcommands: [
            AgentServiceInstallCommand.self,
            AgentServiceStatusCommand.self,
            AgentServiceUninstallCommand.self,
        ]
    )
}

struct AgentServiceInstallCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "install",
        abstract: "Configure and enable the local agent."
    )

    @Argument(help: "Repositories in owner/name form. Repeat a repository to give it another runner slot.")
    var repositories: [String]

    mutating func validate() throws {
        guard !repositories.isEmpty else {
            throw ValidationError("Provide at least one repository.")
        }
        guard repositories.count <= RunnerServiceCommand.maximumSlots else {
            throw ValidationError("The local agent supports at most \(RunnerServiceCommand.maximumSlots) runner slots.")
        }
    }

    mutating func run() throws {
        let service = try localAgentService()
        let locator = ExecutableLocator()
        let configuration = AgentConfiguration(
            repositories: try repositories.map(GitHubRepository.init),
            containerURL: try locator.locate("container"),
            ghURL: try locator.locate("gh")
        )
        let store = try AgentConfigurationStore()

        switch service.status {
        case .enabled, .requiresApproval:
            guard try store.load() == configuration else {
                throw AgentServiceError.configurationChanged
            }
        case .notRegistered, .notFound:
            try store.save(configuration)
            do {
                try service.register()
            } catch where service.status == .requiresApproval {
                break
            }
        @unknown default:
            throw AgentServiceError.unknownStatus
        }

        printRegistrationStatus(service.status)
    }
}

struct AgentServiceStatusCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show local agent registration, configuration, and active runners."
    )

    mutating func run() throws {
        let service = try localAgentService()
        printRegistrationStatus(service.status)

        let store = try AgentConfigurationStore()
        do {
            let configuration = try store.load()
            print("Repositories: \(configuration.repositories.map(\.fullName).joined(separator: ", "))")
            print("container: \(configuration.containerURL.path)")
            print("gh: \(configuration.ghURL.path)")
        } catch AgentConfigurationError.missing {
            print("Configuration: not installed")
        }

        let leases = try RunnerLeaseStore(directory: store.directory).load()
        if leases.isEmpty {
            print("Active runner leases: none")
        } else {
            print("Active runner leases:")
            for lease in leases {
                print("- \(lease.runnerID.value) (\(lease.repository.fullName))")
            }
        }
    }
}

struct AgentServiceUninstallCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "uninstall",
        abstract: "Disable the local agent and remove its configuration."
    )

    mutating func run() throws {
        let service = try localAgentService()
        switch service.status {
        case .enabled, .requiresApproval:
            do {
                try service.unregister()
            } catch where service.status == .notRegistered || service.status == .notFound {
                break
            }
        case .notRegistered, .notFound:
            break
        @unknown default:
            throw AgentServiceError.unknownStatus
        }

        try AgentConfigurationStore().remove()
        print("Local agent unregistered and configuration removed.")
    }
}

private func localAgentService(bundle: Bundle = .main) throws -> SMAppService {
    let plistURL = bundle.bundleURL
        .appendingPathComponent("Contents/Library/LaunchAgents", isDirectory: true)
        .appendingPathComponent(agentPlistName, isDirectory: false)
    guard bundle.bundleURL.pathExtension == "app",
          FileManager.default.fileExists(atPath: plistURL.path) else {
        throw AgentServiceError.notPackaged
    }
    return SMAppService.agent(plistName: agentPlistName)
}

private func printRegistrationStatus(_ status: SMAppService.Status) {
    switch status {
    case .notRegistered, .notFound:
        // Background Task Management has no record before the first registration.
        print("Local agent is not registered.")
    case .enabled:
        print("Local agent is enabled.")
    case .requiresApproval:
        print("Local agent requires approval in System Settings > General > Login Items & Extensions.")
    @unknown default:
        print("Local agent registration status is unknown.")
    }
}

enum AgentServiceError: Error, Equatable, LocalizedError {
    case notPackaged
    case configurationChanged
    case unknownStatus

    var errorDescription: String? {
        switch self {
        case .notPackaged:
            "Local agent service commands must run from the packaged yieldd application."
        case .configurationChanged:
            "The local agent is already configured differently. Uninstall it before changing its configuration."
        case .unknownStatus:
            "macOS returned an unknown local agent registration status."
        }
    }
}
