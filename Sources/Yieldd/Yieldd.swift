import ArgumentParser

@main
struct Yieldd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "yieldd",
        abstract: "Manage ephemeral GitHub Actions runner machines.",
        subcommands: [
            DoctorCommand.self,
            StorageCommand.self,
            RecoverCommand.self,
            MachineTestCommand.self,
            RunnerTestCommand.self,
            RunnerServiceCommand.self,
            ConnectCommand.self,
            AgentCommand.self,
        ]
    )
}
