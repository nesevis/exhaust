import Foundation

/// Resolves target selection and stable workspace identity before executing a build.
struct CampaignPlan {
    let test: PackageTargetDescription
    let targets: [String]
    let scratch: URL
    let statePath: String
    let environment: [String: String]

    init(options: Options, package: PackageDescription, outputDirectory: URL, environment: [String: String]) throws {
        test = try Self.selectTest(in: package, named: options.testTarget)
        for name in options.instruments {
            if options.runtimePackage == .root, package.runtimeTargetNames.contains(name) {
                throw CommandError("The Exhaust fuzz runtime must remain uninstrumented: \(name).")
            }
            guard package.targets.contains(where: { $0.name == name && $0.moduleType == .swift && $0.type.supportsInstrumentation }) else {
                throw CommandError("\(name) is not a root Swift library, executable, or test target. Dependency targets, macros, C targets and binary targets are not supported.")
            }
        }
        targets = Set(options.instruments + [test.name]).sorted()
        let identity = (["overlay-v1", options.configuration.rawValue, options.swift] + targets).joined(separator: "\n")
        scratch = outputDirectory.appendingPathComponent(StableFingerprint.hex(identity))
        statePath = environment["EXHAUST_STATE_DIR"] ?? scratch.appendingPathComponent("state").nativePath
        var campaignEnvironment = environment
        campaignEnvironment["EXHAUST_STATE_DIR"] = statePath
        if let seconds = options.seconds {
            campaignEnvironment["EXHAUST_EXPLORE_TIME_NS"] = String(seconds * 1_000_000_000)
        }
        self.environment = campaignEnvironment
    }

    private static func selectTest(in package: PackageDescription, named name: String?) throws -> PackageTargetDescription {
        let tests = package.targets.filter { $0.type == .test && $0.moduleType == .swift }
        guard let name else {
            guard tests.count == 1, let selected = tests.first else {
                throw CommandError("Select one root Swift test target with --test-target. Available: \(tests.map(\.name).sorted().joined(separator: ", ")).")
            }
            return selected
        }
        guard let selected = tests.first(where: { $0.name == name }) else {
            throw CommandError("No root Swift test target named \(name). Available: \(tests.map(\.name).sorted().joined(separator: ", ")).")
        }
        return selected
    }
}

// MARK: - Test Discovery

struct TestSelection {
    let names: [String]

    init(listing: String, module: String, filter: String?) throws {
        let expression = try filter.map { try NSRegularExpression(pattern: $0) }
        let selected = listing.split(whereSeparator: \.isNewline).map(String.init).filter { name in
            // Compare scalars, not characters: an identifier starting with a combining mark joins the separator into one character.
            guard name.unicodeScalars.starts(with: (module + ".").unicodeScalars) || name.unicodeScalars.starts(with: (module + "/").unicodeScalars) else {
                return false
            }
            guard let expression else {
                return true
            }
            return expression.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil
        }
        guard selected.isEmpty == false else {
            throw CommandError("No tests matched in \(module)\(filter.map { " with filter \($0)" } ?? ""). No tests were run.")
        }
        names = Array(Set(selected)).sorted()
    }

    var executionFilter: String {
        // Swift Testing may append a source location absent from discovery; keep the test boundary while accepting that suffix.
        "^(?:" + names.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|") + ")(?:$|/)"
    }
}

// MARK: - Stable Build Identity

enum StableFingerprint {
    static func hex(_ value: String) -> String {
        let hash = value.utf8.reduce(UInt64(14_695_981_039_346_656_037)) { ($0 ^ UInt64($1)) &* 1_099_511_628_211 }
        return String(hash, radix: 16)
    }
}
