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
        let arguments = Array(CommandLine.arguments.dropFirst())
        do {
            let options = try Options.parse(arguments)
            try CommandRunner(options: options).run()
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
