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
