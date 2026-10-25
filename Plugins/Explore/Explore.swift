import Foundation
import PackagePlugin

@main
struct Explore: CommandPlugin {
    func performCommand(context: PluginContext, arguments: [String]) async throws {
        let runtimeArguments = try Self.runtimeArguments(context: context)
        // Find the parent SwiftPM workspace, including a caller-supplied --scratch-path.
        var workspace = context.pluginWorkDirectoryURL
        while FileManager.default.fileExists(atPath: workspace.appendingPathComponent("workspace-state.json").path) == false {
            let parent = workspace.deletingLastPathComponent()
            if parent.path == workspace.path {
                workspace = context.package.directoryURL.appendingPathComponent(".build")
                break
            }
            workspace = parent
        }
        let process = Process()
        process.executableURL = try context.tool(named: "ExhaustExploreCommand").url
        process.arguments = try [
            "explore", "--package-path", context.package.directoryURL.path,
            "--output-path", context.pluginWorkDirectoryURL.appendingPathComponent("exhaust").path,
            "--swift", context.tool(named: "swift").url.path,
            "--workspace-path", workspace.path,
        ] + runtimeArguments + arguments
        try process.run()
        process.waitUntilExit()
        if process.terminationReason != .exit || process.terminationStatus != 0 {
            throw CommandFailure()
        }
    }

    private static func runtimeArguments(context: PluginContext) throws -> [String] {
        if context.package.products.contains(where: { $0.name == "ExhaustFuzzRuntime" }) {
            return []
        }
        guard let dependency = context.package.dependencies.first(where: {
            $0.package.products.contains(where: { $0.name == "ExhaustFuzzRuntime" })
        }) else {
            throw CommandFailure(message: "The root package must depend directly on Exhaust to link its fuzz runtime.")
        }
        return ["--runtime-package", dependency.package.id]
    }
}

private struct CommandFailure: Error, CustomStringConvertible {
    var message = "The explore command failed; see the build or test diagnostics above."
    var description: String {
        message
    }
}
