import ArgumentParser
import Foundation

struct Options: ParsableArguments {
    // MARK: - Campaign Options

    @Option(name: .customLong("instrument"), help: "Root Swift target to instrument; repeat for additional targets.")
    var instruments: [String] = []

    @Option(help: "Root Swift test target; inferred when the package has only one.")
    var testTarget: String?

    @Option(help: "Run matching tests within the selected test target; no matches fails.")
    var filter: String?

    @Option(
        name: .customLong("time"),
        parsing: .unconditional,
        help: ArgumentHelp("Override each #explore(time:) invocation's budget.", valueName: "seconds"),
        transform: parseSeconds
    )
    var seconds: UInt64?

    @Option(help: "Build configuration for the campaign.")
    var configuration: BuildConfiguration = .release

    // MARK: - Plugin Context

    /// Supplied by the command plugin, not part of the public campaign interface.
    @Option(help: .hidden)
    var packagePath = FileManager.default.currentDirectoryPath

    @Option(help: .hidden)
    var swift = "swift"

    @Option(help: .hidden)
    var runtimePackage = "exhaust"

    @Option(help: .hidden)
    var workspacePath: String?

    @Option(help: .hidden)
    var outputPath: String?

    // MARK: - Validation

    mutating func validate() throws {
        guard !instruments.isEmpty else {
            throw ValidationError("Select at least one root Swift target with --instrument <target>.")
        }
        let stringOptions: [(String, String?)] = [
            ("--package-path", packagePath), ("--swift", swift), ("--runtime-package", runtimePackage),
            ("--workspace-path", workspacePath), ("--output-path", outputPath),
            ("--test-target", testTarget), ("--filter", filter),
        ] + instruments.map { ("--instrument", $0) }
        for (name, value) in stringOptions where value?.isEmpty == true {
            throw ValidationError("\(name) requires a nonempty value.")
        }
        if let filter {
            do {
                _ = try NSRegularExpression(pattern: filter)
            } catch {
                throw ValidationError("--filter must be a valid regular expression: \(error.localizedDescription)")
            }
        }
        packagePath = URL(fileURLWithPath: packagePath).standardizedFileURL.resolvingSymlinksInPath().path
    }
}

// MARK: - Value Parsing

private func parseSeconds(_ value: String) throws -> UInt64 {
    guard let seconds = UInt64(value), seconds > 0, seconds <= UInt64.max / 1_000_000_000 else {
        throw ValidationError("--time must be a positive whole number of seconds representable in nanoseconds.")
    }
    return seconds
}

// MARK: - Supporting Types

enum BuildConfiguration: String, CaseIterable, ExpressibleByArgument {
    case debug
    case release
}
