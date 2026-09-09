import ArgumentParser

@main
struct Yieldd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "yieldd",
        abstract: "Manage ephemeral GitHub Actions runner machines.",
        subcommands: [
            DoctorCommand.self,
            RecoverCommand.self,
            MachineTestCommand.self,
            RunnerTestCommand.self,
            RunnerServiceCommand.self,
            AgentCommand.self,
        ]
    )
}
