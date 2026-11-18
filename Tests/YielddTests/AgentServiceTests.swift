import Foundation
import ServiceManagement
import Testing
@testable import Yieldd

@Test
func agentInstallRecognizesApprovalAfterRegistrationError() throws {
    let fixture = try AgentServiceFixture(status: .notRegistered)
    fixture.registerError = AgentServiceTestError.registrationDenied
    fixture.statusAfterRegister = .requiresApproval

    try enableAgent(service: fixture.service)

    #expect(fixture.registerCalls == 1)
}

@Test
func agentInstallPreservesUnexpectedRegistrationErrors() throws {
    let fixture = try AgentServiceFixture(status: .notRegistered)
    fixture.registerError = AgentServiceTestError.registrationFailed

    #expect(throws: AgentServiceTestError.registrationFailed) {
        try enableAgent(service: fixture.service)
    }
}

@Test
func agentInstallDoesNotConcealServiceNotFound() throws {
    let fixture = try AgentServiceFixture(status: .notFound)

    #expect(throws: AgentError.serviceNotFound) {
        try enableAgent(service: fixture.service)
    }
    #expect(fixture.registerCalls == 0)
}

private final class AgentServiceFixture {
    var status: SMAppService.Status
    var statusAfterRegister: SMAppService.Status?
    var registerError: (any Error)?
    var unregisterError: (any Error)?
    var registerCalls = 0
    var unregisterCalls = 0
    var events: [String] = []

    init(status: SMAppService.Status) throws {
        self.status = status
    }

    var service: LocalAgentService {
        LocalAgentService(
            status: { self.status },
            register: {
                self.registerCalls += 1
                if let statusAfterRegister = self.statusAfterRegister {
                    self.status = statusAfterRegister
                }
                if let registerError = self.registerError {
                    throw registerError
                }
            },
            unregister: {
                self.unregisterCalls += 1
                self.events.append("unregister")
                if let unregisterError = self.unregisterError {
                    throw unregisterError
                }
                self.status = .notRegistered
            }
        )
    }


}

private enum AgentServiceTestError: Error {
    case registrationDenied
    case registrationFailed
    case recoveryFailed
}
