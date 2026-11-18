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
