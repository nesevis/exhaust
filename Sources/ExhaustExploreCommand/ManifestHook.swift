import Foundation
#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

/// Appended only to the root manifest consumed through the compiler overlay.
enum ManifestHook {
    static let compilerFlags = [
        "-sanitize=fuzzer-no-link",
        "-sanitize-coverage=edge,trace-pc-guard,pc-table,trace-cmp",
        "-assert-config", "Debug",
    ]

    /// Appends the campaign hook: instrumented targets gain the coverage runtime and flags, and the test target gains the test-reporting support whether or not it is instrumented.
    static func augment(_ source: String, targets: [String], testTarget: String, runtimePackage: String?) -> String {
        let runtimeDependency = dependency(target: "ExhaustCore", product: "ExhaustFuzzRuntime", package: runtimePackage)
        let testDependency = dependency(target: "ExhaustFuzzTestSupport", product: "ExhaustFuzzTestSupport", package: runtimePackage)
        return source + "\n\n" + """
        for target in package.targets where [\(targets.map { String(reflecting: $0) }.joined(separator: ", "))].contains(target.name) {
            target.dependencies.append(\(runtimeDependency))
            target.swiftSettings = (target.swiftSettings ?? []) + [
                .unsafeFlags([\(compilerFlags.map { String(reflecting: $0) }.joined(separator: ", "))]),
            ]
        }
        for target in package.targets where target.name == \(String(reflecting: testTarget)) {
            target.dependencies.append(\(testDependency))
        }

        """
    }

    private static func dependency(target: String, product: String, package: String?) -> String {
        guard let package else {
            return ".target(name: \(String(reflecting: target)))"
        }
        return ".product(name: \(String(reflecting: product)), package: \(String(reflecting: package)))"
    }

    static func writeOverlay(for manifest: URL, source: String, in scratch: URL) throws -> URL {
        // Put the content fingerprint in the compiler flags so SwiftPM's manifest cache cannot reuse a manifest compiled with an earlier generated hook.
        let fingerprint = StableFingerprint.hex(source)
        let directory = scratch.appendingPathComponent("manifests/\(fingerprint)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let augmented = directory.appendingPathComponent("Package.swift")
        let overlay = directory.appendingPathComponent("overlay.json")
        // Foundation can present /private/var as /var on macOS, while SwiftPM uses realpath. Cover both spellings so the overlay matches its input.
        var paths = Set([manifest.path, manifest.nativePath])
        #if canImport(Darwin) || canImport(Glibc)
            if let resolved = realpath(manifest.path, nil) {
                paths.insert(String(cString: resolved))
                free(resolved)
            }
        #endif
        #if os(Windows)
            paths.formUnion(paths.map { $0.replacingOccurrences(of: "\\", with: "/") })
        #endif
        var mapping: [String: Any] = [
            "version": 0,
            "use-external-names": false,
            "roots": paths.sorted().map { path in [
                "type": "file",
                "name": path,
                "external-contents": augmented.nativePath,
            ] },
        ]
        #if os(Windows)
            mapping["case-sensitive"] = false
        #endif
        let files = try [
            (augmented, Data(source.utf8)),
            (overlay, JSONSerialization.data(withJSONObject: mapping, options: [.sortedKeys])),
        ]
        for (url, data) in files where (try? Data(contentsOf: url)) != data {
            try data.write(to: url, options: .atomic)
        }
        return overlay
    }
}
