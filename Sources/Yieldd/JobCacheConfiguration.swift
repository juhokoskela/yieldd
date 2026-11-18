import Foundation

struct JobCacheConfiguration {
    let data: Data

    static func file(in directory: URL) -> URL { directory.appendingPathComponent("job-caches.json") }

    static func load(in directory: URL) throws -> Self? {
        try readPrivateRunnerFile(file(in: directory), maximumBytes: 64 * 1024).map(Self.init)
    }
}

enum JobCacheError: LocalizedError {
    case invalidScope, invalidDisk, invalidStore, alreadyOpened

    var errorDescription: String? {
        switch self {
        case .invalidScope: "The cache service returned an invalid scope."
        case .invalidDisk: "The job's cache disk changed identity or size. Its contents were discarded."
        case .invalidStore: "The native cache store contains an invalid file or directory."
        case .alreadyOpened: "This job already opened a native cache disk."
        }
    }
}
