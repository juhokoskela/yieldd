import Foundation

func describeError(_ error: any Error) -> String {
    if let localizedError = error as? any LocalizedError,
       let description = localizedError.errorDescription {
        return description
    }
    return String(describing: error)
}

func terminalSafeOutput(_ text: String) -> String {
    var result = ""
    for scalar in text.unicodeScalars {
        let value = scalar.value
        if (value < 32 && value != 9 && value != 10) || (127...159).contains(value)
            || scalar.properties.generalCategory == .format || scalar.properties.isDefaultIgnorableCodePoint {
            result += "\\u{\(String(value, radix: 16))}"
        } else {
            result.unicodeScalars.append(scalar)
        }
    }
    return result
}
