import Foundation

let app = CLIApp()
let result = await app.run(args: Array(CommandLine.arguments.dropFirst()))
if !result.output.isEmpty {
    print(result.output)
}
exit(result.exitCode)
