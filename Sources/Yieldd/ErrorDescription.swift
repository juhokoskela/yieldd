import Foundation

func describeError(_ error: any Error) -> String {
    if let localizedError = error as? any LocalizedError,
       let description = localizedError.errorDescription {
        return description
    }
    return String(describing: error)
}
