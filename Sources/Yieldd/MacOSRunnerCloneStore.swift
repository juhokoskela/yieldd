import Foundation

struct MacOSRunnerCloneStore {
    let rootURL: URL

    func creatingURL(for id: RunnerID) throws -> URL {
        try url(for: id, suffix: "creating")
    }

    func bundleURL(for id: RunnerID) throws -> URL {
        try url(for: id, suffix: "bundle")
    }

    func remove(_ id: RunnerID) throws {
        for url in try [creatingURL(for: id), bundleURL(for: id)] {
            do {
                try FileManager.default.removeItem(at: url)
            } catch CocoaError.fileNoSuchFile {
                continue
            }
        }
    }

    private func url(for id: RunnerID, suffix: String) throws -> URL {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-")
        guard id.value.hasPrefix("yieldd-"), id.value.count <= 128,
              id.value.unicodeScalars.allSatisfy(allowed.contains)
        else {
            throw RunnerLeaseError.invalidRunnerID(path: rootURL.path)
        }
        return rootURL.appendingPathComponent("\(id.value).\(suffix)", isDirectory: true)
    }
}
