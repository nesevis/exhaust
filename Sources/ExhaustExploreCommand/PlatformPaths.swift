import Foundation

extension URL {
    /// Uses the host's file-system spelling, including Windows drive and UNC paths.
    var nativePath: String {
        withUnsafeFileSystemRepresentation { String(cString: $0!) }
    }
}

/// Resolves the standalone helper's compiler without relying on a Unix shell or env executable.
func swiftExecutable(named name: String, environment: [String: String]) throws -> URL {
    if name.contains("/") || name.contains("\\") {
        return URL(fileURLWithPath: name)
    }
    #if os(Windows)
        let separator: Character = ";"
        let executable = name.lowercased().hasSuffix(".exe") ? name : name + ".exe"
    #else
        let separator: Character = ":"
        let executable = name
    #endif
    let path = environment.first { $0.key.caseInsensitiveCompare("PATH") == .orderedSame }?.value ?? ""
    for directory in path.split(separator: separator, omittingEmptySubsequences: true) {
        let url = URL(fileURLWithPath: String(directory)).appendingPathComponent(executable)
        if FileManager.default.isExecutableFile(atPath: url.nativePath) {
            return url
        }
    }
    throw CommandError("Cannot find \(executable) on PATH. Supply --swift with its executable path.")
}
