import Exhaust
import Foundation
import Testing
@testable import ExhaustExploreCommand

@Suite("Explore campaign planning")
struct ExploreCommandTests {
    @Test("Options accumulate targets, accept equals syntax, and use the last scalar value")
    func parseOptions() throws {
        let options = try Options.parse([
            "explore", "--instrument=Library", "--instrument", "Tests",
            "--filter=[", "--filter=valid", "--time", "60", "--configuration", "debug",
        ])
        #expect(options.instruments == ["Library", "Tests"])
        #expect(options.filter == "valid")
        #expect(options.seconds == 60)
        #expect(options.configuration == .debug)
    }

    @Test("Plugin context precedes explore, and user arguments cannot override it", arguments: [
        "--package-path", "--swift", "--runtime-package", "--workspace-path", "--output-path",
    ])
    func pluginContextIsNotUserOption(name: String) throws {
        var arguments = ["--runtime-package", "exhaust", "explore", "--instrument", "Library"][...]
        let invocation = try Invocation.parse(&arguments)
        #expect(invocation.runtimePackage == .dependency(identity: "exhaust"))
        #expect(Array(arguments) == ["explore", "--instrument", "Library"])
        let error = #expect(throws: CommandError.self) {
            try Options.parse(Array(arguments) + [name, "/elsewhere"])
        }
        #expect(error?.description.contains("Unknown option: \(name)") == true)
    }

    @Test("Invalid options fail before any process starts", arguments: [
        ["--time", "0"], ["--time", "-1"], ["--time", "1.5"], ["--time", "18446744074"],
        ["--filter", "["], ["--configuration", "profile"], ["--unknown", "value"],
        ["--test-target"], ["--instrument", ""], ["--test-target="],
    ])
    func invalidOptions(arguments: [String]) {
        #expect(throws: CommandError.self) {
            try Options.parse(["explore", "--instrument", "Library"] + arguments)
        }
    }

    @Test("Instrumentation is required")
    func instrumentationRequired() {
        #expect(throws: CommandError.self) { try Options.parse(["explore"]) }
    }

    @Test("The largest whole-second budget fits in nanoseconds")
    func maximumSeconds() throws {
        #expect(try Options.parseSeconds("18446744073") == 18_446_744_073)
    }

    @Test("Campaigns default to release")
    func defaultConfiguration() throws {
        #expect(try Options.parse(["explore", "--instrument", "Library"]).configuration == .release)
    }

    @Test("Help is recognized only in option position", arguments: ["-h", "--help"])
    func helpPosition(flag: String) throws {
        #expect(throws: HelpRequested.self) { try Options.parse(["explore", flag]) }
        let options = try Options.parse(["explore", "--instrument", "Library", "--filter", flag, "--test-target", flag])
        #expect(options.filter == flag)
        #expect(options.testTarget == flag)
    }

    @Test("Unknown options report their name even without a value")
    func unknownOption() {
        let error = #expect(throws: CommandError.self) {
            try Options.parse(["explore", "--unknown"])
        }
        #expect(error?.description.contains("Unknown option: --unknown") == true)
    }

    @Test("Planning instruments the selected library and test while preserving state overrides")
    func campaignPlan() throws {
        let options = try Options.parse(["explore", "--instrument", "Library", "--time", "2"])
        let plan = try CampaignPlan(
            options: options,
            invocation: Invocation(),
            package: package,
            outputDirectory: URL(fileURLWithPath: "/tmp/explore"),
            environment: ["EXHAUST_STATE_DIR": "/tmp/custom-state"]
        )
        #expect(plan.test.name == "Tests")
        #expect(plan.targets == ["Library", "Tests"])
        #expect(plan.statePath == "/tmp/custom-state")
        #expect(plan.environment["EXHAUST_EXPLORE_TIME_NS"] == "2000000000")
        let repeated = try CampaignPlan(
            options: options,
            invocation: Invocation(),
            package: package,
            outputDirectory: URL(fileURLWithPath: "/tmp/explore"),
            environment: [:]
        )
        #expect(plan.scratch == repeated.scratch)
        #expect(repeated.statePath == repeated.scratch.appendingPathComponent("state").nativePath)
    }

    @Test("Planning rejects unsupported targets", arguments: ["Dependency", "Macro", "ExhaustCore", "RuntimeHelper"])
    func invalidTargets(name: String) throws {
        let options = try Options.parse(["explore", "--instrument", name])
        #expect(throws: CommandError.self) {
            try CampaignPlan(
                options: options,
                invocation: Invocation(),
                package: package,
                outputDirectory: URL(fileURLWithPath: "/tmp"),
                environment: [:]
            )
        }
    }

    @Test("Ambiguous test targets require explicit selection")
    func ambiguousTests() throws {
        let options = try Options.parse(["explore", "--instrument", "Library"])
        #expect(throws: CommandError.self) {
            try CampaignPlan(
                options: options,
                invocation: Invocation(),
                package: ambiguousPackage,
                outputDirectory: URL(fileURLWithPath: "/tmp"),
                environment: [:]
            )
        }
    }

    @Test("Explicit selection resolves an ambiguous test target")
    func explicitTestTarget() throws {
        let options = try Options.parse(["explore", "--instrument", "Library", "--test-target", "OtherTests"])
        let plan = try CampaignPlan(
            options: options,
            invocation: Invocation(),
            package: ambiguousPackage,
            outputDirectory: URL(fileURLWithPath: "/tmp"),
            environment: [:]
        )
        #expect(plan.test.name == "OtherTests")
    }

    @Test("Discovery preserves module boundaries and escapes execution identifiers")
    func testSelection() throws {
        let selection = try TestSelection(listing: """
        Build warning
        Tests.topLevel()
        Tests.Suite/parameterized(value:)
        Tests/Legacy/testMethod
        Tests.topLevel()
        TestsOther.topLevel()
        """, module: "Tests", filter: nil)
        #expect(selection.names.count == 3)
        let expression = try NSRegularExpression(pattern: selection.executionFilter)
        for name in ["Tests.topLevel()", "Tests.Suite/parameterized(value:)/source.swift:20", "Tests/Legacy/testMethod"] {
            #expect(expression.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil)
        }
        for name in ["TestsXtopLevel()", "Tests.topLevel()Other", "TestsOther.topLevel()"] {
            #expect(expression.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) == nil)
        }
        #expect(throws: CommandError.self) { try TestSelection(listing: "Tests.topLevel()", module: "Tests", filter: "absent") }
    }

    @Test("Manifest dependencies resolve their explicit aliases across supported dependency kinds", arguments: ["fileSystem", "sourceControl", "registry"])
    func runtimeAlias(kind: String) throws {
        let source = """
        {"dependencies":[{"\(kind)":[{"identity":"exhaust","nameForTargetDependencyResolutionOnly":"Tooling"}]}],"targets":[]}
        """
        let manifest = try JSONDecoder().decode(PackageManifest.self, from: Data(source.utf8))
        #expect(try manifest.runtimePackageName(for: .dependency(identity: "exhaust")) == "Tooling")
        #expect(try manifest.runtimePackageName(for: .root) == nil)
        #expect(throws: CommandError.self) { try manifest.runtimePackageName(for: .dependency(identity: "absent")) }
    }

    @Test("Verification requires exact unconditional Swift instrumentation flags")
    func instrumentationVerification() throws {
        let flags = ManifestHook.compilerFlags
        let setting = ManifestSetting(tool: "swift", kind: ManifestSettingKind(unsafeFlags: ManifestUnsafeFlags(flags: flags)), condition: nil)
        let valid = PackageManifest(dependencies: [], targets: [ManifestTarget(name: "Library", settings: [setting])])
        try valid.verifyInstrumentation(targets: ["Library"])
        for invalid in [
            ManifestSetting(tool: "c", kind: setting.kind, condition: nil),
            ManifestSetting(tool: "swift", kind: setting.kind, condition: ManifestCondition()),
            ManifestSetting(tool: "swift", kind: ManifestSettingKind(unsafeFlags: ManifestUnsafeFlags(flags: flags.map { $0 + "suffix" })), condition: nil),
        ] {
            let manifest = PackageManifest(dependencies: [], targets: [ManifestTarget(name: "Library", settings: [invalid])])
            #expect(throws: CommandError.self) { try manifest.verifyInstrumentation(targets: ["Library"]) }
        }
    }

    @Test("Manifest augmentation scopes selection and escapes dependency aliases")
    func manifestAugmentation() {
        let source = "let package = Package(name: \"Example\")"
        let augmented = ManifestHook.augment(source, targets: ["Library", "Tests"], runtimePackage: "Tool\"ing")
        #expect(augmented.hasPrefix(source))
        #expect(augmented.contains("[\"Library\", \"Tests\"].contains(target.name)"))
        #expect(augmented.contains("package: \"Tool\\\"ing\""))
        #expect(augmented.contains("EXHAUST_INSTRUMENT") == false)
        #expect(ManifestHook.augment(source, targets: ["Library"], runtimePackage: nil).contains(".target(name: \"ExhaustCore\")"))
    }

    @Test("Generated plugin context and options round-trip through both user argument syntaxes", arguments: ArgumentSyntax.allCases)
    func optionsRoundTrip(syntax: ArgumentSyntax) {
        #exhaust(#gen(CommandGenerators.invocation, CommandGenerators.options)) { invocation, options in
            var arguments = (ArgumentSyntax.arguments(for: invocation) + syntax.arguments(for: options))[...]
            let parsedInvocation = try Invocation.parse(&arguments)
            return try parsedInvocation == invocation && Options.parse(Array(arguments)) == options
        }
    }

    @Test("Execution filters match exactly the selected tests in a discovery listing")
    func generatedExecutionFilters() {
        #exhaust(CommandGenerators.discovery) { discovery in
            let selection = try TestSelection(
                listing: discovery.lines.joined(separator: "\n"),
                module: "Tests",
                filter: discovery.filter
            )
            let expression = try NSRegularExpression(pattern: selection.executionFilter)
            func matches(_ name: String) -> Bool {
                expression.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil
            }
            return selection.names.contains(discovery.anchor)
                && discovery.lines.allSatisfy { line in
                    matches(line) == selection.names.contains(line)
                }
                && selection.names.allSatisfy { name in
                    matches(name + "/" + discovery.executionSuffix)
                }
        }
    }

    @Test("Unknown SwiftPM kinds remain describable but cannot be instrumented")
    func unknownKinds() throws {
        let source = #"{"targets":[{"name":"Future","c99name":"Future","type":"future","module_type":"FutureTarget"}],"products":[]}"#
        let package = try JSONDecoder().decode(PackageDescription.self, from: Data(source.utf8))
        #expect(package.targets[0].type == .other)
        #expect(package.targets[0].moduleType == .other)
    }

    // MARK: - Fixtures

    private var ambiguousPackage: PackageDescription {
        PackageDescription(
            targets: package.targets + [
                PackageTargetDescription(name: "OtherTests", c99name: "OtherTests", type: .test, moduleType: .swift, targetDependencies: nil),
            ],
            products: package.products
        )
    }

    private var package: PackageDescription {
        PackageDescription(
            targets: [
                PackageTargetDescription(name: "Library", c99name: "Library", type: .library, moduleType: .swift, targetDependencies: nil),
                PackageTargetDescription(name: "Tests", c99name: "Tests", type: .test, moduleType: .swift, targetDependencies: nil),
                PackageTargetDescription(name: "Macro", c99name: "Macro", type: .macro, moduleType: .swift, targetDependencies: nil),
                PackageTargetDescription(name: "ExhaustCore", c99name: "ExhaustCore", type: .library, moduleType: .swift, targetDependencies: ["RuntimeHelper"]),
                PackageTargetDescription(name: "RuntimeHelper", c99name: "RuntimeHelper", type: .library, moduleType: .swift, targetDependencies: nil),
            ],
            products: [PackageProductDescription(name: "ExhaustFuzzRuntime", targets: ["ExhaustCore"])]
        )
    }
}

// MARK: - Property Generators

private enum CommandGenerators {
    /// Characters with meaning to regular expressions, option syntax, or test identifiers. Drawn as a separate branch so escaping and `=` splitting are exercised often; the other branch covers the rest of Unicode.
    static let metacharacters = CharacterSet(charactersIn: "\\^$.|?*+()[]{}/=\"-")

    /// Nonempty text without newlines, which separate discovery listing entries, or any `excluded` characters.
    static func text(excluding excluded: CharacterSet = CharacterSet()) -> ReflectiveGenerator<String> {
        let reserved = excluded.union(.newlines)
        let ordinary = #gen(.string(from: reserved.union(metacharacters).inverted, length: 1 ... 6))
        let special = #gen(.string(from: metacharacters.subtracting(reserved), length: 1 ... 6))
        let piece = #gen(.oneOf(ordinary, special))
        return piece.array(length: 1 ... 4).map { $0.joined() }
    }

    static var options: ReflectiveGenerator<Options> {
        let value = text()
        return #gen(
            value.array(length: 1 ... 4),
            value.optional(),
            value.optional(),
            .uint64(in: 1 ... UInt64.max / 1_000_000_000).optional(),
            .element(from: [BuildConfiguration.debug, .release])
        )
        .map { instruments, testTarget, filter, seconds, configuration in
            Options(
                instruments: instruments,
                testTarget: testTarget,
                filter: filter.map(NSRegularExpression.escapedPattern(for:)),
                seconds: seconds,
                configuration: configuration
            )
        }
    }

    static var invocation: ReflectiveGenerator<Invocation> {
        let value = text()
        // Parsing normalizes the package path, so the round trip starts from an already normalized one.
        let packagePath = FileManager.default.temporaryDirectory.standardizedFileURL.resolvingSymlinksInPath().path
        return #gen(value, value.optional(), value.optional(), value.optional())
            .map { swift, runtimeIdentity, workspacePath, outputPath in
                Invocation(
                    packagePath: packagePath,
                    swift: swift,
                    runtimePackage: runtimeIdentity.map { .dependency(identity: $0) } ?? .root,
                    workspacePath: workspacePath,
                    outputPath: outputPath
                )
            }
    }

    /// Swift Testing identifiers. Components exclude `/`, `(`, and `)`, as real suite and function names do, so no identifier is another's `/`-separated prefix.
    static var testIdentifier: ReflectiveGenerator<TestIdentifier> {
        let component = text(excluding: CharacterSet(charactersIn: "/()"))
        return #gen(component.array(length: 0 ... 2), component, component.optional()) { suites, function, label in
            TestIdentifier(suites: suites, function: function, label: label)
        }
    }

    /// A listing with one anchor test that every filter shape selects, sibling tests a filter may exclude, and tests from modules whose names share a prefix with the selected one.
    static var discovery: ReflectiveGenerator<Discovery> {
        let identifier = testIdentifier
        let foreign = #gen(.element(from: ["Other", "Test", "TestsOther"]), identifier)
        return #gen(
            identifier,
            identifier.array(length: 0 ... 4),
            foreign.array(length: 0 ... 4),
            .element(from: FilterShape.allCases),
            text()
        )
        .map { anchor, siblings, foreign, shape, executionSuffix in
            let anchorName = anchor.rendered(in: "Tests")
            let filter: String? = switch shape {
                case .absent:
                    nil
                case .anchorFunction:
                    NSRegularExpression.escapedPattern(for: anchor.function)
                case .exactAnchor:
                    "^" + NSRegularExpression.escapedPattern(for: anchorName) + "$"
            }
            let siblingNames = siblings.map { $0.rendered(in: "Tests") }
            let foreignNames = foreign.map { module, identifier in
                identifier.rendered(in: module)
            }
            return Discovery(
                lines: [anchorName] + siblingNames + foreignNames,
                filter: filter,
                anchor: anchorName,
                executionSuffix: executionSuffix
            )
        }
    }
}

// MARK: - Supporting Types

private struct TestIdentifier {
    let suites: [String]
    let function: String
    let label: String?

    func rendered(in module: String) -> String {
        let arguments = label.map { $0 + ":" } ?? ""
        return module + "." + (suites + [function + "(" + arguments + ")"]).joined(separator: "/")
    }
}

private struct Discovery {
    let lines: [String]
    let filter: String?
    let anchor: String
    let executionSuffix: String
}

private enum FilterShape: CaseIterable {
    case absent
    case anchorFunction
    case exactAnchor
}

enum ArgumentSyntax: CaseIterable {
    case separated
    case equals

    func arguments(for options: Options) -> [String] {
        let values: [(String, String?)] = options.instruments.map { ("--instrument", $0) } + [
            ("--test-target", options.testTarget),
            ("--filter", options.filter),
            ("--time", options.seconds.map(String.init)),
            ("--configuration", options.configuration.rawValue),
        ]
        return ["explore"] + values.flatMap { name, value -> [String] in
            guard let value else {
                return []
            }
            switch self {
                case .separated:
                    return [name, value]
                case .equals:
                    return [name + "=" + value]
            }
        }
    }

    /// The plugin always passes its context as separated pairs, so it has one syntax.
    static func arguments(for invocation: Invocation) -> [String] {
        let runtime: String? = switch invocation.runtimePackage {
            case .root:
                nil
            case let .dependency(identity):
                identity
        }
        let values: [(String, String?)] = [
            ("--package-path", invocation.packagePath),
            ("--swift", invocation.swift),
            ("--runtime-package", runtime),
            ("--workspace-path", invocation.workspacePath),
            ("--output-path", invocation.outputPath),
        ]
        return values.flatMap { name, value in
            value.map { [name, $0] } ?? []
        }
    }
}
