import Foundation
#if os(Windows)
    import ucrt
#elseif canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

@main
struct ExploreCommand {
    static func main() {
        var arguments = CommandLine.arguments.dropFirst()
        do {
            let invocation = try Invocation.parse(&arguments)
            let options = try Options.parse(Array(arguments))
            try CommandRunner(options: options, invocation: invocation).run()
        } catch is HelpRequested {
            print(Options.help)
        } catch let failure as ChildFailure {
            exit(failure.status)
        } catch {
            FileHandle.standardError.write(Data("error: \(error)\n".utf8))
            exit(1)
        }
    }
}
