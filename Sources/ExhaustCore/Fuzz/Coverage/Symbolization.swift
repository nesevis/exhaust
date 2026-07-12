// Report-time resolution of discriminating edge indices to source symbols.

import Foundation

#if canImport(Darwin)
    import Darwin
#endif

/// swift_demangle lives in the Swift runtime; a null return means the input was not a mangled Swift name.
@_silgen_name("swift_demangle")
private func stdlibDemangle(
    mangledName: UnsafePointer<CChar>?,
    mangledNameLength: UInt,
    outputBuffer: UnsafeMutablePointer<CChar>?,
    outputBufferSize: UnsafeMutablePointer<UInt>?,
    flags: UInt32
) -> UnsafeMutablePointer<CChar>?

/// Resolves global edge indices to human-readable source locations via the PC table.
///
/// Two stages, degrading gracefully: `dladdr` gives a demangled symbol plus offset in-process and for free; on macOS, one `atos` subprocess per report upgrades those to file:line by reading DWARF. Edges without a PC-table entry (synthetic sources, builds without `pc-table`) are omitted from the result — callers render the bare edge index.
package enum SancovSymbolizer {
    /// Resolves each edge to a description like `parseHeader(_:) + 48 (Parser.swift:142)`, best effort.
    ///
    /// - Complexity: One `dladdr` per edge plus at most one subprocess spawn per distinct loaded image, once per report — never on the exploration hot path.
    package static func symbolize(edges: [Int]) -> [Int: String] {
        #if canImport(Darwin)
            var descriptions: [Int: String] = [:]
            var atosTargets: [AtosImage: [(edge: Int, programCounter: UInt)]] = [:]

            for edge in edges {
                guard let entry = SancovRuntime.pcTableEntry(forEdge: edge),
                      let address = UnsafeRawPointer(bitPattern: entry.programCounter)
                else {
                    continue
                }
                var info = Dl_info()
                guard dladdr(address, &info) != 0 else {
                    continue
                }
                if let symbol = info.dli_sname {
                    let mangled = String(cString: symbol)
                    let name = demangle(mangled) ?? mangled
                    let offset = entry.programCounter - UInt(bitPattern: info.dli_saddr)
                    descriptions[edge] = offset == 0 ? name : "\(name) + \(offset)"
                } else if let imagePath = info.dli_fname {
                    descriptions[edge] = URL(fileURLWithPath: String(cString: imagePath)).lastPathComponent
                }
                if let imagePath = info.dli_fname, info.dli_fbase != nil {
                    let image = AtosImage(
                        path: String(cString: imagePath),
                        loadAddress: UInt(bitPattern: info.dli_fbase)
                    )
                    atosTargets[image, default: []].append((edge, entry.programCounter))
                }
            }

            #if os(macOS)
                for (image, targets) in atosTargets {
                    upgradeWithAtos(image: image, targets: targets, into: &descriptions)
                }
            #endif
            return descriptions
        #else
            _ = edges
            return [:]
        #endif
    }

    #if canImport(Darwin)
        private struct AtosImage: Hashable {
            let path: String
            let loadAddress: UInt
        }

        private static func demangle(_ mangled: String) -> String? {
            mangled.withCString { cString in
                guard let demangled = stdlibDemangle(
                    mangledName: cString,
                    mangledNameLength: UInt(strlen(cString)),
                    outputBuffer: nil,
                    outputBufferSize: nil,
                    flags: 0
                ) else {
                    return nil
                }
                defer {
                    free(demangled)
                }
                return String(cString: demangled)
            }
        }
    #endif

    #if os(macOS)
        /// Runs `atos` once for one image and appends `(File.swift:line)` to each edge whose output carries source information. Failures leave the dladdr descriptions untouched.
        private static func upgradeWithAtos(
            image: AtosImage,
            targets: [(edge: Int, programCounter: UInt)],
            into descriptions: inout [Int: String]
        ) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/atos")
            process.arguments = ["-o", image.path, "-l", String(format: "0x%lx", image.loadAddress)]
                + targets.map { String(format: "0x%lx", $0.programCounter) }
            let stdout = Pipe()
            process.standardOutput = stdout
            process.standardError = Pipe()
            do {
                try process.run()
            } catch {
                return
            }
            let data = stdout.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0, let output = String(data: data, encoding: .utf8) else {
                return
            }
            // One output line per input address, in order: "name (in Module) (File.swift:123)".
            let lines = output.split(separator: "\n", omittingEmptySubsequences: false)
            for (index, target) in targets.enumerated() where index < lines.count {
                let line = String(lines[index])
                guard let sourceRange = line.range(of: #"\(([^()]+:\d+)\)\s*$"#, options: .regularExpression) else {
                    continue
                }
                let source = line[sourceRange].dropFirst().dropLast()
                if let existing = descriptions[target.edge] {
                    descriptions[target.edge] = "\(existing) (\(source))"
                } else {
                    descriptions[target.edge] = String(source)
                }
            }
        }
    #endif
}
