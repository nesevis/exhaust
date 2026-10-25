import Foundation
#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#elseif canImport(ucrt)
    import ucrt
#endif

/// All child commands use argument arrays; package paths, target names and regexes are never shell code.
struct CommandRunner {
    let options: Options
    let fileManager = FileManager.default

    var root: URL {
        URL(fileURLWithPath: options.packagePath)
    }

    /// SwiftPM grants the plugin write access to its work directory without package permissions.
    var outputDirectory: URL {
        options.outputPath.map { URL(fileURLWithPath: $0) } ?? root.appendingPathComponent(".build/exhaust")
    }

    var manifest: URL {
        root.appendingPathComponent("Package.swift")
    }

    var cleanEnvironment: [String: String] {
        var environment = ProcessInfo.processInfo.environment
        for key in ["EXHAUST_INSTRUMENT_PACKAGE", "EXHAUST_INSTRUMENT_TARGETS", "EXHAUST_EXPLORE_TIME_NS", "EXHAUST_RUNTIME_PACKAGE"] {
            environment.removeValue(forKey: key)
        }
        return environment
    }

    func log(_ message: String) {
        FileHandle.standardOutput.write(Data((message + "\n").utf8))
    }

    func run() throws {
        // SwiftPM may select a version-specific manifest instead of the file we overlay.
        let versioned = try fileManager.contentsOfDirectory(atPath: root.path)
            .filter { $0.hasPrefix("Package@swift-") && $0.hasSuffix(".swift") }
        guard versioned.isEmpty else {
            throw CommandError("Version-specific manifests are not supported by explore yet: \(versioned.sorted().joined(separator: ", ")).")
        }
        try explore()
    }

    func explore() throws {
        let source = try String(contentsOf: manifest, encoding: .utf8)
        let augmentedManifest = try ManifestHook.augment(source)
        let description = try swift("package", ["describe", "--type", "json"], environment: cleanEnvironment, capture: true)
        let package = try JSONDecoder().decode(PackageDescription.self, from: description)
        let tests = package.targets.filter { $0.type == "test" && $0.moduleType == "SwiftTarget" }
        let test: PackageTargetDescription
        if let name = options.testTarget {
            guard let selected = tests.first(where: { $0.name == name }) else {
                throw CommandError("No root Swift test target named \(name). Available: \(tests.map(\.name).sorted().joined(separator: ", ")).")
            }
            test = selected
        } else {
            guard tests.count == 1, let selected = tests.first else {
                throw CommandError("Select one root Swift test target with --test-target. Available: \(tests.map(\.name).sorted().joined(separator: ", ")).")
            }
            test = selected
        }
        for name in options.instruments {
            if options.runtimePackage == "__root__", ["ExhaustCore", "ExhaustCoverageRuntime", "ExhaustObjCSupport"].contains(name) {
                throw CommandError("The Exhaust fuzz runtime must remain uninstrumented: \(name).")
            }
            guard package.targets.contains(where: { $0.name == name && $0.moduleType == "SwiftTarget" && ["library", "executable", "test"].contains($0.type) }) else {
                throw CommandError("\(name) is not a root Swift library, executable, or test target. Dependency targets, macros, C targets and binary targets are not supported.")
            }
        }
        let targets = Set(options.instruments + [test.name]).sorted()
        var environment = cleanEnvironment
        environment["EXHAUST_INSTRUMENT_PACKAGE"] = root.path
        guard let targetJSON = try String(bytes: JSONEncoder().encode(targets), encoding: .utf8) else {
            throw CommandError("Cannot encode instrumentation targets as UTF-8 JSON.")
        }
        environment["EXHAUST_INSTRUMENT_TARGETS"] = targetJSON
        environment["EXHAUST_RUNTIME_PACKAGE"] = try runtimePackageName()
        let identity = (["overlay-v1", options.configuration.rawValue, options.swift] + targets).joined(separator: "\n")
        let fingerprint = identity.utf8.reduce(UInt64(14_695_981_039_346_656_037)) { ($0 ^ UInt64($1)) &* 1_099_511_628_211 }
        let scratch = outputDirectory.appendingPathComponent(String(fingerprint, radix: 16))
        try fileManager.createDirectory(at: scratch, withIntermediateDirectories: true)
        // A stable state directory permits crash recovery; the lock prevents overlapping runs from sharing it.
        let buildLock = try BuildLock(directory: scratch)
        defer { withExtendedLifetime(buildLock) {} }
        let overlay = try ManifestHook.writeOverlay(for: manifest, source: augmentedManifest, in: scratch)
        // Verify the evaluated manifest before compiling any targets.
        let evaluated = try swift("package", ["dump-package"], environment: environment, capture: true, manifestOverlay: overlay)
        try verifyInstrumentation(evaluated, targets: targets)
        try seedDependencies(in: scratch)
        let attachments = scratch.appendingPathComponent("attachments/\(UUID().uuidString)")
        try fileManager.createDirectory(at: attachments, withIntermediateDirectories: true)
        environment["EXHAUST_STATE_DIR"] = environment["EXHAUST_STATE_DIR"] ?? scratch.appendingPathComponent("state").nativePath
        if let seconds = options.seconds {
            environment["EXHAUST_EXPLORE_TIME_NS"] = String(seconds * 1_000_000_000)
        }
        log("Instrumenting root targets: \(targets.joined(separator: ", "))")
        log("Build: \(scratch.nativePath)")
        log("Attachments: \(attachments.nativePath)")
        log("Crash recovery state: \(environment["EXHAUST_STATE_DIR"]!)")
        if let seconds = options.seconds {
            log("Budget: \(seconds)s per #explore(time:) invocation")
        }
        let buildOptions = ["--scratch-path", scratch.nativePath, "--configuration", options.configuration.rawValue]
        _ = try swift("build", buildOptions + ["--build-tests"], environment: environment, manifestOverlay: overlay)
        let listing = try swift("test", buildOptions + ["list", "--skip-build"], environment: environment, capture: true, manifestOverlay: overlay)
        guard let testListing = String(bytes: listing, encoding: .utf8) else {
            throw CommandError("Test discovery returned invalid UTF-8 output.")
        }
        let selected = try selectTests(testListing, module: test.c99name, filter: options.filter)
        log("Running \(selected.count) test(s) in \(test.name).")
        // Swift Testing appends a source-location component to some IDs at execution time;
        // `swift test list` omits it. Preserve the test boundary without excluding that suffix.
        let filter = "^(?:" + selected.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|") + ")(?:$|/)"
        _ = try swift("test", buildOptions + [
            "--skip-build", "--no-parallel", "--filter", filter,
            "--attachments-path", attachments.nativePath,
        ], environment: environment, manifestOverlay: overlay)
    }

    func verifyInstrumentation(_ data: Data, targets: [String]) throws {
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let descriptions = object?["targets"] as? [[String: Any]] ?? []
        for target in targets {
            guard let description = descriptions.first(where: { $0["name"] as? String == target }),
                  let settings = description["settings"],
                  let text = try String(data: JSONSerialization.data(withJSONObject: settings), encoding: .utf8),
                  text.contains("-sanitize-coverage=edge,trace-pc-guard,pc-table,trace-cmp")
            else {
                throw CommandError("The ephemeral manifest did not enable coverage for \(target).")
            }
        }
    }

    /// Command plugins cannot fetch arbitrary dependencies through their sandbox. The parent
    /// already resolved them before loading the plugin; copy its workspace state and source
    /// checkouts, not its build products. Private copies also prevent fuzz builds from changing
    /// ordinary build checkouts. Refresh when the parent's resolution changes.
    func seedDependencies(in scratch: URL) throws {
        let workspace = options.workspacePath.map { URL(fileURLWithPath: $0) } ?? root.appendingPathComponent(".build")
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

    /// SwiftPM permits an explicit dependency name that differs from its canonical identity.
    func runtimePackageName() throws -> String {
        if options.runtimePackage == "__root__" {
            return "__root__"
        }
        let data = try swift("package", ["dump-package"], environment: cleanEnvironment, capture: true)
        let manifest = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        for dependency in manifest?["dependencies"] as? [[String: Any]] ?? [] {
            for kind in ["fileSystem", "sourceControl", "registry"] {
                for entry in dependency[kind] as? [[String: Any]] ?? [] where entry["identity"] as? String == options.runtimePackage {
                    return entry["nameForTargetDependencyResolutionOnly"] as? String ?? options.runtimePackage
                }
            }
        }
        throw CommandError("The root package must depend directly on Exhaust to link its fuzz runtime.")
    }

    func selectTests(_ listing: String, module: String, filter: String?) throws -> [String] {
        let expression = try filter.map { try NSRegularExpression(pattern: $0) }
        let names = listing.split(whereSeparator: \.isNewline).map(String.init).filter { name in
            // Top-level Swift Testing functions have no suite/test slash.
            guard name.hasPrefix(module + ".") || name.hasPrefix(module + "/") else {
                return false
            }
            guard let expression else {
                return true
            }
            return expression.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil
        }
        guard !names.isEmpty else {
            throw CommandError("No tests matched in \(module)\(filter.map { " with filter \($0)" } ?? ""). No tests were run.")
        }
        return Array(Set(names)).sorted()
    }

    @discardableResult
    func swift(_ command: String, _ arguments: [String], environment: [String: String], capture: Bool = false, manifestOverlay: URL? = nil) throws -> Data {
        let process = Process()
        process.executableURL = try swiftExecutable(named: options.swift, environment: environment)
        process.arguments = [command]
        // Prebuilt SwiftSyntax downloads require network/keychain access that a command
        // plugin's parent sandbox does not grant. Its source checkout is already resolved.
        process.arguments! += ["--package-path", root.nativePath, "--disable-sandbox", "--disable-experimental-prebuilts", "--manifest-cache", "local"]
        if let manifestOverlay {
            process.arguments! += [
                "-Xbuild-tools-swiftc", "-vfsoverlay",
                "-Xbuild-tools-swiftc", manifestOverlay.nativePath,
            ]
        }
        // The outer `swift package` holds its workspace lock while running a command plugin.
        // Even manifest inspection needs a separate workspace to avoid waiting on our parent.
        if !arguments.contains("--scratch-path") {
            process.arguments! += ["--scratch-path", outputDirectory.appendingPathComponent("metadata").nativePath]
        }
        process.arguments! += arguments
        process.currentDirectoryURL = root
        process.environment = environment
        // Read while the child is running so a large discovery/manifest response cannot fill a pipe.
        let pipe = capture ? Pipe() : nil
        if let pipe {
            process.standardOutput = pipe
        }
        try process.run()
        let data = pipe?.fileHandleForReading.readDataToEndOfFile() ?? Data()
        process.waitUntilExit()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            if capture, !data.isEmpty {
                FileHandle.standardError.write(data)
            }
            throw ChildFailure(status: process.terminationReason == .exit ? process.terminationStatus : 128 + process.terminationStatus)
        }
        return data
    }
}

// MARK: - Package Metadata

private struct PackageDescription: Decodable {
    let targets: [PackageTargetDescription]
}

private struct PackageTargetDescription: Decodable {
    let name: String
    let c99name: String
    let type: String
    let moduleType: String?

    enum CodingKeys: String, CodingKey {
        case name, c99name, type
        case moduleType = "module_type"
    }
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
