import Foundation

struct GitHubRepository: Equatable, Sendable {
    let owner: String
    let name: String

    init(_ value: String) throws {
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2,
              Self.isValidOwner(parts[0]),
              Self.isValidRepositoryName(parts[1]) else {
            throw GitHubRepositoryError.invalidFormat(value)
        }

        owner = String(parts[0])
        name = String(parts[1])
    }

    var fullName: String {
        "\(owner)/\(name)"
    }

    fileprivate var apiPath: String {
        "repos/\(owner)/\(name)"
    }

    private static func isValidOwner(_ owner: Substring) -> Bool {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-")
        guard (1...39).contains(owner.count),
              owner.unicodeScalars.allSatisfy(allowed.contains) else {
            return false
        }
        return (owner.first?.isLetter == true || owner.first?.isNumber == true)
            && (owner.last?.isLetter == true || owner.last?.isNumber == true)
    }

    private static func isValidRepositoryName(_ name: Substring) -> Bool {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._")
        return (1...100).contains(name.count)
            && name != "."
            && name != ".."
            && name.unicodeScalars.allSatisfy(allowed.contains)
    }
}

enum GitHubRepositoryError: Error, Equatable, LocalizedError {
    case invalidFormat(String)

    var errorDescription: String? {
        "Repository must use the owner/name format accepted by GitHub."
    }
}

protocol GitHubRunnerManaging {
    func createRegistrationToken(for repository: GitHubRepository) throws -> String
    func removeRunners(named name: String, from repository: GitHubRepository) throws
}

struct GitHubRunnerClient: GitHubRunnerManaging {
    static let registrationTimeout: TimeInterval = 30
    static let cleanupTimeout: TimeInterval = 30

    let ghURL: URL
    let executor: any ProcessExecuting

    func createRegistrationToken(for repository: GitHubRepository) throws -> String {
        let data = try run(
            method: "POST",
            endpoint: "\(repository.apiPath)/actions/runners/registration-token",
            timeout: Self.registrationTimeout
        ).stdout

        do {
            let response = try JSONDecoder().decode(RegistrationTokenResponse.self, from: data)
            guard !response.token.isEmpty else {
                throw GitHubRunnerClientError.missingRegistrationToken
            }
            return response.token
        } catch let error as GitHubRunnerClientError {
            throw error
        } catch {
            throw GitHubRunnerClientError.invalidResponse(
                operation: "create a runner registration token",
                underlying: error
            )
        }
    }

    func removeRunners(named name: String, from repository: GitHubRepository) throws {
        for runner in try runners(named: name, in: repository) where runner.name == name {
            guard !runner.busy else {
                throw GitHubRunnerClientError.runnerBusy(name: name)
            }
            do {
                _ = try run(
                    method: "DELETE",
                    endpoint: "\(repository.apiPath)/actions/runners/\(runner.id)",
                    timeout: Self.cleanupTimeout,
                    cancellable: false
                )
            } catch {
                let deletionError = error
                guard let remainingRunners = try? runners(named: name, in: repository) else {
                    throw deletionError
                }
                guard let remainingRunner = remainingRunners.first(where: { $0.id == runner.id }) else {
                    continue
                }
                if remainingRunner.busy {
                    throw GitHubRunnerClientError.runnerBusy(name: name)
                }
                throw deletionError
            }
        }
    }

    private func runners(named name: String, in repository: GitHubRepository) throws -> [GitHubRunner] {
        let result = try run(
            endpoint: "\(repository.apiPath)/actions/runners",
            extraArguments: ["--paginate", "--slurp", "--raw-field", "name=\(name)"],
            timeout: Self.cleanupTimeout,
            cancellable: false
        )

        do {
            return try JSONDecoder().decode([RunnerPage].self, from: result.stdout)
                .flatMap(\.runners)
        } catch {
            throw GitHubRunnerClientError.invalidResponse(
                operation: "list repository runners",
                underlying: error
            )
        }
    }

    private func run(
        method: String = "GET",
        endpoint: String,
        extraArguments: [String] = [],
        timeout: TimeInterval? = nil,
        cancellable: Bool = true
    ) throws -> ProcessResult {
        var arguments = ["api", "--method", method]
        arguments.append(contentsOf: extraArguments)
        arguments.append(contentsOf: [
            "--header", "Accept: application/vnd.github+json",
            "--header", "X-GitHub-Api-Version: 2026-03-10",
            endpoint,
        ])

        let request = ProcessRequest(
            executableURL: ghURL,
            arguments: arguments,
            timeout: timeout,
            cancellable: cancellable
        )
        return try executor.execute(request).requireSuccess(for: request)
    }
}

enum GitHubRunnerClientError: Error {
    case missingRegistrationToken
    case invalidResponse(operation: String, underlying: any Error)
    case runnerBusy(name: String)
}

extension GitHubRunnerClientError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .missingRegistrationToken:
            "GitHub returned an empty runner registration token."
        case let .invalidResponse(operation, underlying):
            "Could not \(operation): \(underlying.localizedDescription)"
        case let .runnerBusy(name):
            "GitHub still considers runner \(name) busy."
        }
    }
}

private struct RegistrationTokenResponse: Decodable {
    let token: String
}

private struct RunnerPage: Decodable {
    let runners: [GitHubRunner]
}

private struct GitHubRunner: Decodable {
    let id: Int64
    let name: String
    let busy: Bool
}
