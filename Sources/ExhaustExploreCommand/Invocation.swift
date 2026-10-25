import Foundation

/// Values the plugin resolves from its context, passed before `explore` so the user's arguments cannot override them.
struct Invocation: Equatable {
    var packagePath = FileManager.default.currentDirectoryPath
    var swift = "swift"
    var runtimePackage: RuntimePackage = .root
    var workspacePath: String?
    var outputPath: String?

    /// Consumes `--name value` pairs up to `explore`, leaving `explore` and the user's arguments in `arguments`.
    static func parse(_ arguments: inout ArraySlice<String>) throws -> Invocation {
        var invocation = Invocation()
        while let name = arguments.first, name != "explore" {
            arguments.removeFirst()
            guard let value = arguments.popFirst(), value.isEmpty == false else {
                throw CommandError("\(name) requires a nonempty value.")
            }
            switch name {
                case "--package-path":
                    invocation.packagePath = value
                case "--swift":
                    invocation.swift = value
                case "--runtime-package":
                    invocation.runtimePackage = .dependency(identity: value)
                case "--workspace-path":
                    invocation.workspacePath = value
                case "--output-path":
                    invocation.outputPath = value
                default:
                    throw CommandError("Unknown plugin option: \(name).")
            }
        }
        invocation.packagePath = URL(fileURLWithPath: invocation.packagePath).standardizedFileURL.resolvingSymlinksInPath().path
        return invocation
    }
}

enum RuntimePackage: Equatable {
    case root
    case dependency(identity: String)
}
