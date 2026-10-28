import Foundation

/// Locates the trap probe executables the crash-recovery tests spawn.
public enum TrapProbe {
    /// The executable built beside the running test bundle, falling back to the package's conventional build layouts.
    ///
    /// The products directory comes first because `swift package explore` builds into its own scratch directory: a probe under `.build/debug` there is a stale, separately configured build. Discovery of the package root starts from this file's source path rather than the test runner's path, which under `swift test` is a system helper nowhere near the products.
    public static func url(named name: String) -> URL? {
        let fileManager = FileManager.default
        #if canImport(ObjectiveC)
            let products = Bundle(for: BundleToken.self).bundleURL.deletingLastPathComponent()
            let sibling = products.appendingPathComponent(name)
            if fileManager.isExecutableFile(atPath: sibling.path) {
                return sibling
            }
        #endif
        var root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0 ..< 8 {
            if fileManager.fileExists(atPath: root.appendingPathComponent("Package.swift").path) {
                break
            }
            root = root.deletingLastPathComponent()
        }
        let buildRoot = root.appendingPathComponent(".build")
        for configuration in ["debug", "release"] {
            let candidate = buildRoot.appendingPathComponent(configuration).appendingPathComponent(name)
            if fileManager.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        guard let enumerator = fileManager.enumerator(at: buildRoot, includingPropertiesForKeys: [.isDirectoryKey]) else {
            return nil
        }
        for case let url as URL in enumerator where url.lastPathComponent == name {
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDirectory == false, fileManager.isExecutableFile(atPath: url.path) {
                return url
            }
        }
        return nil
    }
}

// MARK: - Helpers

/// Anchors `Bundle(for:)` to the test bundle this support library is linked into.
private final class BundleToken {}
