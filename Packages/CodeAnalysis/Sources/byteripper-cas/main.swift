import CodeAnalysis
import Foundation

// The store's command line, for the skill's Python and for a person: all of
// it is `CASCommand`, so the tool and the app run the same code.
let output = CASCommand.run(Array(CommandLine.arguments.dropFirst()))
FileHandle.standardOutput.write(output.stdout)
FileHandle.standardError.write(output.stderr)
exit(output.status)
