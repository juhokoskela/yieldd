import Foundation
import Testing
@testable import Yieldd

@Test
func guestDiagnosticRenderingEscapesTerminalControlsButRetainsRawResult() {
    let output = "failure\u{1b}]52;c;YXR0YWNr\u{7}\rhidden\u{8}\u{9b}2J\n\tää🙂"
    let expected = "failure\\u{1b}]52;c;YXR0YWNr\\u{7}\\u{d}hidden\\u{8}\\u{9b}2J\n\tää🙂"
    let request = ProcessRequest(executableURL: URL(fileURLWithPath: "/test/ssh"), arguments: [])
    let result = processResult(stderr: output, status: 7)
    let process = ProcessExecutionError.nonZeroExit(request: request, result: result)
    let listener = RunnerAssignmentError.listenerFailed(7, output: output)
    #expect(describeError(process).hasSuffix(expected))
    #expect(describeError(listener).hasSuffix(expected))
    #expect(result.stderrText == output)
    #expect(terminalSafeOutput("ordinary\n\ttext") == "ordinary\n\ttext")
}

@Test(arguments: [
    0x00ad, 0x034f, 0x0600, 0x061c, 0x115f, 0x1160, 0x17b4, 0x180e,
    0x200b, 0x200c, 0x200d, 0x200e, 0x200f, 0x202a, 0x202b, 0x202c, 0x202d, 0x202e,
    0x2060, 0x2061, 0x2062, 0x2063, 0x2064, 0x2066, 0x2067, 0x2068, 0x2069,
    0xfeff, 0xfe0f, 0xe0001, 0xe007f, 0xe0100,
] as [UInt32])
func guestDiagnosticRenderingEscapesUnicodeFormatting(_ value: UInt32) throws {
    let scalar = try #require(Unicode.Scalar(value))
    let output = "before\(scalar)after"
    let expected = "before\\u{\(String(value, radix: 16))}after"
    let request = ProcessRequest(executableURL: URL(fileURLWithPath: "/test/ssh"), arguments: [])
    let result = processResult(stderr: output, status: 7)
    #expect(describeError(ProcessExecutionError.nonZeroExit(request: request, result: result)).hasSuffix(expected))
    #expect(describeError(RunnerAssignmentError.listenerFailed(7, output: output)).hasSuffix(expected))
    #expect(result.stderrText == output)
}

@Test
func guestDiagnosticRenderingPreservesVisibleUnicode() {
    let text = "ää e\u{301} 中文 العربية עברית 🙂\n\ttext"
    #expect(terminalSafeOutput(text) == text)
}
