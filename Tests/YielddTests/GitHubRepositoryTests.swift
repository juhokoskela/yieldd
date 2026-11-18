import Foundation
import Testing
@testable import Yieldd

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
