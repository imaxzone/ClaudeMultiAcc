import Foundation

let status = await CommandRouter.standard.run(Array(CommandLine.arguments.dropFirst()))
exit(status)
