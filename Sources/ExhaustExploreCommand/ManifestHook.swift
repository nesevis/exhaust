import Foundation
#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

/// Appended only to the build-local manifest consumed through the compiler overlay.
/// The package path prevents the environment from enabling hooks in dependencies.
enum ManifestHook {
    static let begin = "// BEGIN EXHAUST EXPLORE INSTRUMENTATION v1"
    static let end = "// END EXHAUST EXPLORE INSTRUMENTATION"
    static let text = #"""
    // BEGIN EXHAUST EXPLORE INSTRUMENTATION v1
    import Foundation

    if ProcessInfo.processInfo.environment["EXHAUST_INSTRUMENT_PACKAGE"] ==
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().resolvingSymlinksInPath().path,
        let exhaustTargetJSON = ProcessInfo.processInfo.environment["EXHAUST_INSTRUMENT_TARGETS"],
        let exhaustTargets = try? JSONDecoder().decode([String].self, from: Data(exhaustTargetJSON.utf8)),
        let exhaustRuntimePackage = ProcessInfo.processInfo.environment["EXHAUST_RUNTIME_PACKAGE"]
    {
        for target in package.targets where exhaustTargets.contains(target.name) {
            // Every binary linking this target needs the coverage callbacks, even if
            // that binary's own tests do not import Exhaust.
            target.dependencies.append(exhaustRuntimePackage == "__root__"
                ? .target(name: "ExhaustCore")
                : .product(name: "ExhaustFuzzRuntime", package: exhaustRuntimePackage))
            if target.type == .test {
                target.dependencies.append(exhaustRuntimePackage == "__root__"
                    ? .target(name: "ExhaustFuzzTestSupport")
                    : .product(name: "ExhaustFuzzTestSupport", package: exhaustRuntimePackage))
            }
            target.swiftSettings = (target.swiftSettings ?? []) + [
                .unsafeFlags([
                    // Exhaust supplies the coverage runtime; no sanitizer runtime is linked.
                    "-sanitize=fuzzer-no-link",
                    "-sanitize-coverage=edge,trace-pc-guard,pc-table,trace-cmp",
                    "-assert-config", "Debug",
                ]),
            ]
        }
    }
    // END EXHAUST EXPLORE INSTRUMENTATION
    """#

    static func augment(_ source: String) throws -> String {
        // Accept the exact hook installed by the earlier workflow without applying it twice.
        try isInstalled(in: source) ? source : source + "\n\n" + text + "\n"
    }

    static func writeOverlay(for manifest: URL, source: String, in scratch: URL) throws -> URL {
        // Put the content fingerprint in the compiler flags so SwiftPM's manifest cache
        // cannot reuse a manifest compiled with an earlier generated hook.
        let fingerprint = source.utf8.reduce(UInt64(14_695_981_039_346_656_037)) { ($0 ^ UInt64($1)) &* 1_099_511_628_211 }
        let directory = scratch.appendingPathComponent("manifests/\(String(fingerprint, radix: 16))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let augmented = directory.appendingPathComponent("Package.swift")
        let overlay = directory.appendingPathComponent("overlay.json")
        // Foundation can present /private/var as /var on macOS, while SwiftPM
        // uses realpath. Cover both spellings so the overlay matches its input.
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

    static func isInstalled(in source: String) throws -> Bool {
        let begins = source.components(separatedBy: "// BEGIN EXHAUST EXPLORE INSTRUMENTATION").count - 1
        let ends = source.components(separatedBy: end).count - 1
        guard begins != 0 || ends != 0 else {
            return false
        }
        guard begins == 1, ends == 1, source.contains(text) else {
            throw CommandError("The existing Exhaust manifest hook was edited or uses another version. Remove its marked block; explore now provides instrumentation without modifying Package.swift.")
        }
        return true
    }
}
