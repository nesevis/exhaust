import Foundation

struct PackageDescription: Decodable {
    let targets: [PackageTargetDescription]
    let products: [PackageProductDescription]

    var runtimeTargetNames: Set<String> {
        var pending = products.first { $0.name == "ExhaustFuzzRuntime" }?.targets ?? []
        var visited = Set<String>()
        while let name = pending.popLast() {
            guard visited.insert(name).inserted else {
                continue
            }
            pending += targets.first { $0.name == name }?.targetDependencies ?? []
        }
        return visited
    }
}

struct PackageProductDescription: Decodable {
    let name: String
    let targets: [String]
}

struct PackageTargetDescription: Decodable {
    let name: String
    let c99name: String
    let type: TargetKind
    let moduleType: ModuleKind?
    let targetDependencies: [String]?

    enum CodingKeys: String, CodingKey {
        case name, c99name, type
        case moduleType = "module_type"
        case targetDependencies = "target_dependencies"
    }
}

// MARK: - Evaluated Manifest

struct PackageManifest: Decodable {
    let dependencies: [ManifestDependency]
    let targets: [ManifestTarget]

    func runtimePackageName(for runtime: RuntimePackage) throws -> String? {
        guard case let .dependency(identity) = runtime else {
            return nil
        }
        let entries = dependencies.flatMap { ($0.fileSystem ?? []) + ($0.sourceControl ?? []) + ($0.registry ?? []) }
        guard let dependency = entries.first(where: { $0.identity == identity }) else {
            throw CommandError("The root package must depend directly on Exhaust to link its fuzz runtime.")
        }
        return dependency.nameForTargetDependencyResolutionOnly ?? identity
    }

    func verifyInstrumentation(targets names: [String]) throws {
        for name in names {
            guard let target = targets.first(where: { $0.name == name }) else {
                throw CommandError("The ephemeral manifest did not enable coverage for \(name).")
            }
            let flags = target.settings.filter { $0.tool == "swift" && $0.condition == nil }
                .flatMap { $0.kind.unsafeFlags?.flags ?? [] }
            guard ManifestHook.compilerFlags.allSatisfy(flags.contains) else {
                throw CommandError("The ephemeral manifest did not enable coverage for \(name).")
            }
        }
    }
}

// MARK: - Manifest Fields

struct ManifestDependency: Decodable {
    let fileSystem: [ManifestDependencyIdentity]?
    let sourceControl: [ManifestDependencyIdentity]?
    let registry: [ManifestDependencyIdentity]?
}

struct ManifestDependencyIdentity: Decodable {
    let identity: String
    let nameForTargetDependencyResolutionOnly: String?
}

struct ManifestTarget: Decodable {
    let name: String
    let settings: [ManifestSetting]
}

struct ManifestSetting: Decodable {
    let tool: String
    let kind: ManifestSettingKind
    let condition: ManifestCondition?
}

struct ManifestSettingKind: Decodable {
    let unsafeFlags: ManifestUnsafeFlags?
}

struct ManifestUnsafeFlags: Decodable {
    let flags: [String]

    enum CodingKeys: String, CodingKey {
        case flags = "_0"
    }
}

/// Any condition makes a setting unsuitable as proof of unconditional campaign instrumentation.
struct ManifestCondition: Decodable {}

// MARK: - SwiftPM Target Kinds

enum TargetKind: String, Decodable {
    case library
    case executable
    case test
    case macro
    case other

    init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: value) ?? .other
    }

    var supportsInstrumentation: Bool {
        switch self {
            case .library, .executable, .test:
                return true
            case .macro, .other:
                return false
        }
    }
}

enum ModuleKind: String, Decodable {
    case swift = "SwiftTarget"
    case other

    init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: value) ?? .other
    }
}
