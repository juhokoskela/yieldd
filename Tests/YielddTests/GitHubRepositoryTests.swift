import Foundation
import Testing
@testable import Yieldd

@Test
func acceptsRepositoryFullName() throws {
    try validateGitHubRepository("juhokoskela/yieldd")
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
        try validateGitHubRepository(value)
    }
}
