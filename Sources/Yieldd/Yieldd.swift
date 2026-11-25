import ArgumentParser
import Foundation

@main
enum Entrypoint {
    @MainActor static func main() async {
        if CommandLine.arguments.count == 1, let executable = CommandLine.arguments.first,
           URL(fileURLWithPath: executable).lastPathComponent == "yieldd-menu" {
            runCompanion()
        } else {
            await Yieldd.main()
        }
    }
}

struct Yieldd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "yieldd",
        abstract: "Manage ephemeral GitHub Actions runner machines.",
        subcommands: [
            DoctorCommand.self,
            StorageCommand.self,
            RecoverCommand.self,
            MachineTestCommand.self,
            ConnectCommand.self,
            AgentCommand.self,
        ]
    )
}
