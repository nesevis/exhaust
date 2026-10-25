import Foundation

/// Executes a campaign without modifying the root package or its dependency checkouts.
struct CommandRunner {
    let options: Options
    let invocation: Invocation
    let fileManager = FileManager.default

    var root: URL {
        URL(fileURLWithPath: invocation.packagePath)
    }

    var outputDirectory: URL {
        invocation.outputPath.map { URL(fileURLWithPath: $0) } ?? root.appendingPathComponent(".build/exhaust")
    }

    var metadataDirectory: URL {
        // The outer SwiftPM process holds its workspace lock, so even inspection needs a separate workspace.
        outputDirectory.appendingPathComponent("metadata")
    }

    var cleanEnvironment: [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "EXHAUST_EXPLORE_TIME_NS")
        return environment
    }

    // MARK: - Campaign Execution

    func run() throws {
        let versioned = try fileManager.contentsOfDirectory(atPath: root.path)
            .filter { $0.hasPrefix("Package@swift-") && $0.hasSuffix(".swift") }
        guard versioned.isEmpty else {
            throw CommandError("Version-specific manifests are not supported by explore yet: \(versioned.sorted().joined(separator: ", ")).")
        }
        let description = try swift("package", ["describe", "--type", "json"], scratch: metadataDirectory, environment: cleanEnvironment, output: .capture)
        let package = try JSONDecoder().decode(PackageDescription.self, from: description)
        let plan = try CampaignPlan(
            options: options,
            invocation: invocation,
            package: package,
            outputDirectory: outputDirectory,
            environment: cleanEnvironment
        )
        let runtimePackage = try readManifest().runtimePackageName(for: invocation.runtimePackage)
        try fileManager.createDirectory(at: plan.scratch, withIntermediateDirectories: true)
        let buildLock = try BuildLock(directory: plan.scratch)
        defer { withExtendedLifetime(buildLock) {} }
        let manifest = root.appendingPathComponent("Package.swift")
        let source = try String(contentsOf: manifest, encoding: .utf8)
        let augmented = ManifestHook.augment(source, targets: plan.targets, runtimePackage: runtimePackage)
        let overlay = try ManifestHook.writeOverlay(for: manifest, source: augmented, in: plan.scratch)
        try readManifest(overlay: overlay).verifyInstrumentation(targets: plan.targets)
        try seedDependencies(in: plan.scratch)
        try execute(plan, overlay: overlay)
    }

    private func execute(_ plan: CampaignPlan, overlay: URL) throws {
        let attachments = plan.scratch.appendingPathComponent("attachments/\(UUID().uuidString)")
        try fileManager.createDirectory(at: attachments, withIntermediateDirectories: true)
        log("Instrumenting root targets: \(plan.targets.joined(separator: ", "))")
        log("Build: \(plan.scratch.nativePath)")
        log("Attachments: \(attachments.nativePath)")
        log("Crash recovery state: \(plan.statePath)")
        if let seconds = options.seconds {
            log("Budget: \(seconds)s per #explore(time:) invocation")
        }
        let buildOptions = ["--configuration", options.configuration.rawValue]
        try swift("build", buildOptions + ["--build-tests"], scratch: plan.scratch, environment: plan.environment, manifestOverlay: overlay)
        let listing = try swift("test", buildOptions + ["list", "--skip-build"], scratch: plan.scratch, environment: plan.environment, output: .capture, manifestOverlay: overlay)
        guard let text = String(bytes: listing, encoding: .utf8) else {
            throw CommandError("Test discovery returned invalid UTF-8 output.")
        }
        let selection = try TestSelection(listing: text, module: plan.test.c99name, filter: options.filter)
        log("Running \(selection.names.count) test(s) in \(plan.test.name).")
        try swift("test", buildOptions + [
            "--skip-build", "--no-parallel", "--filter", selection.executionFilter,
            "--attachments-path", attachments.nativePath,
        ], scratch: plan.scratch, environment: plan.environment, manifestOverlay: overlay)
    }

    private func readManifest(overlay: URL? = nil) throws -> PackageManifest {
        let data = try swift("package", ["dump-package"], scratch: metadataDirectory, environment: cleanEnvironment, output: .capture, manifestOverlay: overlay)
        return try JSONDecoder().decode(PackageManifest.self, from: data)
    }

    // MARK: - Workspace Preparation

    /// The plugin sandbox cannot fetch dependencies; seed the isolated workspace from the parent's resolved sources. Private copies also prevent fuzz builds from changing ordinary build checkouts.
    func seedDependencies(in scratch: URL) throws {
        let workspace = invocation.workspacePath.map { URL(fileURLWithPath: $0) } ?? root.appendingPathComponent(".build")
        let stateURL = workspace.appendingPathComponent("workspace-state.json")
        guard fileManager.fileExists(atPath: stateURL.path) else {
            return
        }
        let state = try Data(contentsOf: stateURL)
        let stamp = scratch.appendingPathComponent("exhaust-parent-workspace.json")
        if (try? Data(contentsOf: stamp)) == state {
            return
        }
        log("Preparing resolved dependencies for the isolated fuzz build…")
        for name in ["checkouts", "repositories", "artifacts", "workspace-state.json"] {
            let source = workspace.appendingPathComponent(name)
            let destination = scratch.appendingPathComponent(name)
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            if fileManager.fileExists(atPath: source.path) {
                try fileManager.copyItem(at: source, to: destination)
            }
        }
        try state.write(to: stamp, options: .atomic)
    }

    // MARK: - Child Processes

    private func log(_ message: String) {
        FileHandle.standardOutput.write(Data((message + "\n").utf8))
    }

    @discardableResult
    func swift(
        _ command: String,
        _ arguments: [String],
        scratch: URL,
        environment: [String: String],
        output: ProcessOutput = .inherit,
        manifestOverlay: URL? = nil
    ) throws -> Data {
        let process = Process()
        process.executableURL = try PlatformPaths.swiftExecutable(named: invocation.swift, environment: environment)
        var commandArguments = [command, "--scratch-path", scratch.nativePath]
        // Prebuilt SwiftSyntax downloads require network/keychain access that a command plugin's parent sandbox does not grant. Its source checkout is already resolved.
        commandArguments += ["--package-path", root.nativePath, "--disable-sandbox", "--disable-experimental-prebuilts", "--manifest-cache", "local"]
        if let manifestOverlay {
            commandArguments += [
                "-Xbuild-tools-swiftc", "-vfsoverlay",
                "-Xbuild-tools-swiftc", manifestOverlay.nativePath,
            ]
        }
        commandArguments += arguments
        process.arguments = commandArguments
        process.currentDirectoryURL = root
        process.environment = environment
        // Read while the child is running so a large discovery/manifest response cannot fill a pipe.
        let pipe = output == .capture ? Pipe() : nil
        if let pipe {
            process.standardOutput = pipe
        }
        try process.run()
        let data = pipe?.fileHandleForReading.readDataToEndOfFile() ?? Data()
        process.waitUntilExit()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            if output == .capture, data.isEmpty == false {
                FileHandle.standardError.write(data)
            }
            throw ChildFailure(status: process.terminationReason == .exit ? process.terminationStatus : 128 + process.terminationStatus)
        }
        return data
    }
}

enum ProcessOutput {
    case inherit
    case capture
}

// MARK: - Errors

struct ChildFailure: Error {
    let status: Int32
}

struct CommandError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) {
        self.description = description
    }
}
