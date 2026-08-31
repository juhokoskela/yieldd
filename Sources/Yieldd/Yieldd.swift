import ArgumentParser

@main
struct Yieldd: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "yieldd",
        abstract: "Manage ephemeral GitHub Actions runner machines.",
        subcommands: [
            DoctorCommand.self,
            MachineTestCommand.self,
            RunnerTestCommand.self,
            RunnerServiceCommand.self,
        ]
    )
}
