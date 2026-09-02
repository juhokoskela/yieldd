import Foundation

struct ExecutableLocator {
    let searchPath: String
    private let fileManager: FileManager

    init(
        searchPath: String = ProcessInfo.processInfo.environment["PATH"] ?? "",
        fileManager: FileManager = .default
    ) {
        self.searchPath = searchPath
        self.fileManager = fileManager
    }

    func locate(_ name: String) throws -> URL {
        guard !name.isEmpty, !name.contains("/") else {
            throw ExecutableLocatorError.invalidName(name)
        }

        let directories = searchPath
            .split(separator: ":", omittingEmptySubsequences: false)
            .map(String.init)
        guard directories.allSatisfy({ !$0.isEmpty }) else {
            throw ExecutableLocatorError.emptySearchPathComponent
        }
        for directory in directories {
            let candidate = URL(fileURLWithPath: directory, isDirectory: true)
                .appendingPathComponent(name, isDirectory: false)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: candidate.path, isDirectory: &isDirectory) else {
                continue
            }
            if !isDirectory.boolValue, fileManager.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }

        throw ExecutableLocatorError.notFound(name: name, searchedDirectories: directories)
    }
}

enum ExecutableLocatorError: Error, Equatable {
    case invalidName(String)
    case emptySearchPathComponent
    case notFound(name: String, searchedDirectories: [String])
}

extension ExecutableLocatorError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case let .invalidName(name):
            "Invalid executable name: \(name)"
        case .emptySearchPathComponent:
            "PATH must not contain empty components; yieldd does not interpret them as the working directory."
        case let .notFound(name, searchedDirectories):
            "Could not find executable \(name) in PATH directories: \(searchedDirectories.joined(separator: ", "))"
        }
    }
}
