import Foundation
import Testing
@testable import Yieldd

private let ghURL = URL(fileURLWithPath: "/opt/homebrew/bin/gh")
private let repository = try! GitHubRepository("owner/repository")
private let apiHeaders = [
    "--header", "Accept: application/vnd.github+json",
    "--header", "X-GitHub-Api-Version: 2026-03-10",
]

@Test
func parsesRepositoryFullName() throws {
    let repository = try GitHubRepository("juhokoskela/yieldd")

    #expect(repository.owner == "juhokoskela")
    #expect(repository.name == "yieldd")
    #expect(repository.fullName == "juhokoskela/yieldd")
}

@Test(arguments: [
    "owner",
    "owner/",
    "/repository",
    "-owner/repository",
    "owner-/repository",
    "owner/..",
    "owner/repository/extra",
    "owner/repo name",
])
func rejectsInvalidRepositoryFullName(_ value: String) {
    #expect(throws: GitHubRepositoryError.invalidFormat(value)) {
        try GitHubRepository(value)
    }
}

@Test
func createsRegistrationTokenWithAuthenticatedGitHubCLI() throws {
    let executor = RecordingProcessExecutor(outcomes: [
        .success(processResult(stdout: #"{"token":"registration-token","expires_at":"2026-08-31T20:00:00Z"}"#)),
    ])
    let client = GitHubRunnerClient(ghURL: ghURL, executor: executor)

    let token = try client.createRegistrationToken(for: repository)

    #expect(token == "registration-token")
    #expect(executor.requests == [ProcessRequest(
        executableURL: ghURL,
        arguments: ["api", "--method", "POST"] + apiHeaders + [
            "repos/owner/repository/actions/runners/registration-token",
        ]
    )])
}

@Test
func removesOnlyExactRunnerNameMatches() throws {
    let executor = RecordingProcessExecutor(outcomes: [
        .success(processResult(stdout: #"[{"runners":[{"id":41,"name":"yieldd-test-1-old"},{"id":42,"name":"yieldd-test-1"}]}]"#)),
        .success(processResult()),
    ])
    let client = GitHubRunnerClient(ghURL: ghURL, executor: executor)

    try client.removeRunners(named: "yieldd-test-1", from: repository)

    #expect(executor.requests.map(\.arguments) == [
        ["api", "--method", "GET", "--paginate", "--slurp"] + apiHeaders + [
            "repos/owner/repository/actions/runners",
        ],
        ["api", "--method", "DELETE"] + apiHeaders + [
            "repos/owner/repository/actions/runners/42",
        ],
    ])
}

@Test
func missingRunnerNeedsNoDeleteRequest() throws {
    let executor = RecordingProcessExecutor(outcomes: [
        .success(processResult(stdout: #"[{"runners":[]}]"#)),
    ])
    let client = GitHubRunnerClient(ghURL: ghURL, executor: executor)

    try client.removeRunners(named: "yieldd-test-1", from: repository)

    #expect(executor.requests.count == 1)
}

@Test
func acceptsDeleteFailureWhenRunnerDisappearedConcurrently() throws {
    let executor = RecordingProcessExecutor(outcomes: [
        .success(processResult(stdout: #"[{"runners":[{"id":42,"name":"yieldd-test-1"}]}]"#)),
        .success(processResult(stderr: "gh: Not Found (HTTP 404)", status: 1)),
        .success(processResult(stdout: #"[{"runners":[]}]"#)),
    ])
    let client = GitHubRunnerClient(ghURL: ghURL, executor: executor)

    try client.removeRunners(named: "yieldd-test-1", from: repository)

    #expect(executor.requests.map(\.arguments) == [
        ["api", "--method", "GET", "--paginate", "--slurp"] + apiHeaders + [
            "repos/owner/repository/actions/runners",
        ],
        ["api", "--method", "DELETE"] + apiHeaders + [
            "repos/owner/repository/actions/runners/42",
        ],
        ["api", "--method", "GET", "--paginate", "--slurp"] + apiHeaders + [
            "repos/owner/repository/actions/runners",
        ],
    ])
}

@Test
func preservesDeleteFailureWhenRunnerStillExists() {
    let runners = #"[{"runners":[{"id":42,"name":"yieldd-test-1"}]}]"#
    let deletionFailure = processResult(stderr: "permission denied", status: 1)
    let executor = RecordingProcessExecutor(outcomes: [
        .success(processResult(stdout: runners)),
        .success(deletionFailure),
        .success(processResult(stdout: runners)),
    ])
    let client = GitHubRunnerClient(ghURL: ghURL, executor: executor)

    do {
        try client.removeRunners(named: "yieldd-test-1", from: repository)
        Issue.record("Expected runner deletion to fail")
    } catch let ProcessExecutionError.nonZeroExit(request, result) {
        #expect(request == executor.requests[1])
        #expect(result == deletionFailure)
    } catch {
        Issue.record("Unexpected error: \(error)")
    }

    #expect(executor.requests.count == 3)
}

@Test
func rejectsMalformedRegistrationTokenResponse() {
    let executor = RecordingProcessExecutor(outcomes: [
        .success(processResult(stdout: #"{"expires_at":"2026-08-31T20:00:00Z"}"#)),
    ])
    let client = GitHubRunnerClient(ghURL: ghURL, executor: executor)

    #expect(throws: GitHubRunnerClientError.self) {
        try client.createRegistrationToken(for: repository)
    }
}
