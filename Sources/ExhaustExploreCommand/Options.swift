import Foundation

struct Options: Equatable {
    var instruments: [String] = []
    var testTarget: String?
    var filter: String?
    var seconds: UInt64?
    var configuration: BuildConfiguration = .release

    // MARK: - Parsing

    static func parse(_ arguments: [String]) throws -> Options {
        var options = Options()
        var remaining = arguments[...]
        guard remaining.popFirst() == "explore" else {
            throw CommandError("Expected explore. Use --help for usage.")
        }
        while let argument = remaining.popFirst() {
            // Split scalars, not characters: a value starting with a combining mark joins `=` into one character.
            let parts = argument.unicodeScalars.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let name = String(parts[0])
            func value() throws -> String {
                let value: String
                switch parts.count {
                    case 2:
                        value = String(parts[1])
                    default:
                        guard let next = remaining.popFirst() else {
                            throw CommandError("\(name) requires a value.")
                        }
                        value = next
                }
                guard value.isEmpty == false else {
                    throw CommandError("\(name) requires a nonempty value.")
                }
                return value
            }
            switch name {
                case "-h", "--help":
                    guard parts.count == 1 else {
                        throw CommandError("\(name) does not accept a value.")
                    }
                    throw HelpRequested()
                case "--instrument":
                    try options.instruments.append(value())
                case "--test-target":
                    options.testTarget = try value()
                case "--filter":
                    options.filter = try value()
                case "--time":
                    options.seconds = try parseSeconds(value())
                case "--configuration":
                    guard let configuration = try BuildConfiguration(rawValue: value()) else {
                        throw CommandError("--configuration must be debug or release.")
                    }
                    options.configuration = configuration
                default:
                    throw CommandError("Unknown option: \(name). Use --help for usage.")
            }
        }
        try options.validate()
        return options
    }

    static func parseSeconds(_ value: String) throws -> UInt64 {
        guard let seconds = UInt64(value), seconds > 0, seconds <= UInt64.max / 1_000_000_000 else {
            throw CommandError("--time must be a positive whole number of seconds representable in nanoseconds.")
        }
        return seconds
    }

    func validate() throws {
        guard instruments.isEmpty == false else {
            throw CommandError("Select at least one root Swift target with --instrument <target>.")
        }
        if let filter {
            do {
                _ = try NSRegularExpression(pattern: filter)
            } catch {
                throw CommandError("--filter must be a valid regular expression: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Help

    static let help = """
    USAGE: swift package explore --instrument <target> [options]

    Build selected root targets with coverage instrumentation and run tests.
    Instrumentation uses an ephemeral manifest overlay; Package.swift is never edited.
    The selected test target is instrumented too, except on Windows. Dependencies retain their own settings.
    Builds and attachments stay in the plugin work directory. Tests' own time limits still apply.

    OPTIONS:
      --instrument <target>       Root Swift target to instrument; repeat for additional targets.
      --test-target <target>      Root Swift test target; inferred when there is only one.
      --filter <regex>            Run matching tests in the selected target; no matches fails.
      --time <seconds>            Positive whole seconds per #explore(time:) invocation.
      --configuration <mode>      debug or release (default: release).
      -h, --help                  Show this help.

    Options accept --name=value or --name value. Repeated scalar options use the last value.
    SwiftPM options such as --package-path and --scratch-path go before explore.
    """
}

// MARK: - Supporting Types

enum BuildConfiguration: String {
    case debug
    case release
}

struct HelpRequested: Error {}
