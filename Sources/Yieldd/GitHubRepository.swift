import Foundation

func validateGitHubRepository(_ value: String) throws {
    let parts = value.split(separator: "/", omittingEmptySubsequences: false)
    guard parts.count == 2,
          isValidOwner(parts[0]),
          isValidRepositoryName(parts[1]) else {
        throw GitHubRepositoryError.invalidFormat(value)
    }
}

private func isValidOwner(_ owner: Substring) -> Bool {
    let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-")
    guard (1...39).contains(owner.count),
          owner.unicodeScalars.allSatisfy(allowed.contains) else {
        return false
    }
    return (owner.first?.isLetter == true || owner.first?.isNumber == true)
        && (owner.last?.isLetter == true || owner.last?.isNumber == true)
}

private func isValidRepositoryName(_ name: Substring) -> Bool {
    let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._")
    return (1...100).contains(name.count)
        && name != "."
        && name != ".."
        && name.unicodeScalars.allSatisfy(allowed.contains)
}

enum GitHubRepositoryError: Error, Equatable, LocalizedError {
    case invalidFormat(String)

    var errorDescription: String? {
        "Repository must use the owner/name format accepted by GitHub."
    }
}
