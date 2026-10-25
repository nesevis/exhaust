import Foundation
import PackagePlugin

@main
struct Explore: CommandPlugin {
    func performCommand(context: PluginContext, arguments: [String]) async throws {
        let runtimePackage: String
        if context.package.products.contains(where: { $0.name == "ExhaustFuzzRuntime" }) {
            runtimePackage = "__root__"
        } else if let dependency = context.package.dependencies.first(where: {
            $0.package.products.contains(where: { $0.name == "ExhaustFuzzRuntime" })
        }) {
            runtimePackage = dependency.package.id
        } else {
            throw CommandFailure()
        }
        // Find the parent SwiftPM workspace, including a caller-supplied --scratch-path.
        var workspace = context.pluginWorkDirectoryURL
        while !FileManager.default.fileExists(atPath: workspace.appendingPathComponent("workspace-state.json").path) {
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
            "--runtime-package", runtimePackage,
            "--workspace-path", workspace.path,
        ] + arguments
        try process.run()
        process.waitUntilExit()
        if process.terminationReason != .exit || process.terminationStatus != 0 {
            throw CommandFailure()
        }
    }
}

private struct CommandFailure: Error, CustomStringConvertible {
    var description: String {
        "The explore command failed; see the build or test diagnostics above."
    }
}
