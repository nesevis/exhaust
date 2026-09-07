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

/// One instrumented edge resolved to the symbol that contains it, as structured fields rather than a composed string, so a renderer prints what it needs and never parses.
///
/// `displayName` is the demangler's simplified form, the one the debugger prints (`stlcGetType(_:_:)`, `RegLabel.allBelow.getter`): module, argument types, return type, and private discriminators dropped, context kept. `fullName` is the plain `swift_demangle` output for readers who want the types. Specialized copies of a function carry the function's own names, so they fold onto it. `file` and `line` come from debug info and are absent when it cannot place the address; an `atos` `<stdin>` answer reads as absent, because the symbol is real and the file is not.
package struct SymbolLocation: Sendable, Equatable {
    /// The symbol as the linker names it; what compiler-generated classification reads.
    package let mangled: String
    /// The first identifier of a mangled Swift name, or nil for a symbol that is not Swift.
    package let module: String?
    /// The simplified demangling, or the full one where the simplifier is unavailable.
    package let displayName: String
    /// The full demangling, with argument and return types.
    package let fullName: String
    /// The source file's last path component, when debug info placed the address.
    package let file: String?
    /// The source line, when debug info placed the address. Zero from the symbolizer means "in this function, line unknown" and is stored as nil.
    package let line: Int?

    package init(mangled: String, module: String?, displayName: String, fullName: String, file: String?, line: Int?) {
        self.mangled = mangled
        self.module = module
        self.displayName = displayName
        self.fullName = fullName
        self.file = file
        self.line = line
    }

    /// The reader's form: `stlcGetType(_:_:) (STLC.swift:91)`, the file alone when no line resolved, the name alone when no file did. A byte offset means nothing to a reader and is never printed.
    package var rendered: String {
        guard let file else {
            return displayName
        }
        if let line, line > 0 {
            return "\(displayName) (\(file):\(line))"
        }
        return "\(displayName) (\(file))"
    }

    /// Whether `other` names the same place: the same symbol, no file disagreement, and no two resolved lines that differ. Two resolved lines that differ are distinct locations within one function, worth separate entries.
    package func namesSamePlace(as other: SymbolLocation) -> Bool {
        guard displayName == other.displayName, module == other.module else {
            return false
        }
        if let file, let otherFile = other.file, file != otherFile {
            return false
        }
        if let line, line > 0, let otherLine = other.line, otherLine > 0, line != otherLine {
            return false
        }
        return true
    }

    /// Whether debug info placed the address in a synthesized body (a derived conformance, a property wrapper's backing accessor), which the compiler files under `/<compiler-generated>`. Not a place to look.
    package var isSynthesized: Bool {
        file?.contains("<compiler-generated>") == true
    }
}

/// Resolves global edge indices to source symbols via the PC table, once per report.
///
/// Three stages, each degrading gracefully: `dladdr` gives the mangled symbol in-process and for free, and compiler-generated globals are dropped there on the mangled name; on macOS one `swift-demangle -simplified` spawn per report renders every surviving name the way the debugger does, and one `atos` spawn per distinct image reads DWARF for file and line. Edges without a PC-table entry (synthetic sources, builds without `pc-table`) are omitted from the result.
package enum SancovSymbolizer {
    /// Resolves each edge to its symbol, best effort. Edges that resolve into compiler-generated globals are omitted.
    ///
    /// - Complexity: One `dladdr` per edge plus at most one subprocess spawn per distinct loaded image and one for the simplifier, once per report, never on the exploration hot path.
    package static func symbolize(edges: [Int]) -> [Int: SymbolLocation] {
        #if canImport(Darwin)
            var resolved: [Int: (mangled: String, module: String?, fullName: String)] = [:]
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
                    // Classified on the mangled name, where the ABI documents the generated globals as suffixes, not on demangled prose. Nothing a reader can open sits behind a metadata accessor or a reabstraction thunk, so the edge is omitted rather than described.
                    guard isCompilerGenerated(mangled: mangled) == false else {
                        continue
                    }
                    let fullName = stripSpecialization(demangle(mangled) ?? mangled)
                    resolved[edge] = (mangled, moduleName(ofMangled: mangled), fullName)
                }
                // A stripped image gives dladdr the load address and no name; atos can still read the dSYM, so the address is queued either way and an unnamed edge takes its name from there.
                if let imagePath = info.dli_fname, info.dli_fbase != nil {
                    let image = AtosImage(
                        path: String(cString: imagePath),
                        loadAddress: UInt(bitPattern: info.dli_fbase)
                    )
                    atosTargets[image, default: []].append((edge, entry.programCounter))
                }
            }

            var displayNames: [String: String] = [:]
            var sources: [Int: AtosLine] = [:]
            #if os(macOS)
                displayNames = simplifiedNames(forMangled: Array(Set(resolved.values.map(\.mangled))))
                for (image, targets) in atosTargets {
                    sources.merge(sourceLocations(image: image, targets: targets)) { _, new in new }
                }
                // Edges dladdr could not name: atos's own name, when it produced one, stands in for the mangled form, with no module to classify by.
                for (edge, line) in sources where resolved[edge] == nil {
                    guard let name = line.name else {
                        continue
                    }
                    resolved[edge] = (name, nil, stripSpecialization(name))
                }
            #endif

            var locations: [Int: SymbolLocation] = [:]
            for (edge, symbol) in resolved {
                let source = sources[edge]
                locations[edge] = SymbolLocation(
                    mangled: symbol.mangled,
                    module: symbol.module,
                    displayName: displayNames[symbol.mangled] ?? symbol.fullName,
                    fullName: symbol.fullName,
                    file: source?.file,
                    line: source?.line.flatMap { $0 > 0 ? $0 : nil }
                )
            }
            return locations
        #else
            _ = edges
            return [:]
        #endif
    }

    /// Whether a mangled Swift symbol names a compiler-generated global rather than a function a reader can open.
    ///
    /// The suffixes are the ABI's own (`docs/ABI/Mangling.rst`, Globals): the eight the runtime's backtracer hides through `_swift_backtrace_isThunkFunction` (partial-application forwarders `TA`/`Ta`, Objective-C bridging thunks `To`/`TO`, reabstraction thunks `TR`/`Tr`, protocol witness thunks `TW`, allocating constructors `fC`, whose body lives in the initializing `fc`), plus the metadata and witness-table globals (`Ma` accessor, `Mn` descriptor, `MP` pattern, `ML` cache, `WV`/`WP`/`Wp`/`WI`/`WL` witness tables), outlined value operations (`WOy`/`WOe`/`WOr`/`WOs`/`WOh`), merged functions (`Tm`), and self-conformance witnesses (`TS`). Specializations (`Tf`, `Tg`, `TG`, `Ts`) are deliberately not here: a specialized copy of a user function is still that function, and ``stripSpecialization(_:)`` folds it back onto its name. A non-Swift symbol is never generated.
    package static func isCompilerGenerated(mangled: String) -> Bool {
        guard isSwiftMangled(mangled) else {
            return false
        }
        let suffixes = [
            "TA", "Ta", "To", "TO", "TR", "Tr", "TW", "fC",
            "Ma", "Mn", "MP", "ML", "WV", "WP", "Wp", "WI", "WL",
            "WOy", "WOe", "WOr", "WOs", "WOh", "Tm", "TS",
        ]
        return suffixes.contains { mangled.hasSuffix($0) }
    }

    /// Reduces a demangled specialization to the function it specializes, so the report folds it onto the same source location as the unspecialized copy.
    ///
    /// The full demangler prints a specialization as a wrapper (`function signature specialization <Arg[2] = Dead> of Module.f()`, `generic specialization <Swift.Int> of Module.g()`) and the simplifier as a prefix (`specialized f(_:)`); both are removed.
    package static func stripSpecialization(_ demangled: String) -> String {
        if demangled.hasPrefix("specialized ") {
            return String(demangled.dropFirst("specialized ".count))
        }
        let wrappers = ["function signature specialization <", "generic specialization <", "generic not re-abstracted specialization <", "specialization <"]
        guard wrappers.contains(where: { demangled.hasPrefix($0) }),
              let range = demangled.range(of: "> of ", options: .backwards)
        else {
            return demangled
        }
        return String(demangled[range.upperBound...])
    }

    /// The module a mangled Swift name belongs to: the length-prefixed identifier that follows the mangling prefix, or nil when the name is not Swift or does not start with an identifier (a symbol in the standard library, whose module is the `s` substitution, reads as `Swift`).
    package static func moduleName(ofMangled mangled: String) -> String? {
        guard isSwiftMangled(mangled) else {
            return nil
        }
        var rest = Substring(mangled)
        for prefix in ["_$s", "$s", "_$S", "$S", "_T0", "_T"] where rest.hasPrefix(prefix) {
            rest = rest.dropFirst(prefix.count)
            break
        }
        // A module name is a length-prefixed identifier, so the position is a digit for every module but the standard library, which the mangling names by the `s` substitution (`$ss5print…`) or by one of its known-type substitutions (`Sa` array, `SS` string, `Si` integer).
        if rest.first == "s" || rest.first == "S" {
            return "Swift"
        }
        let digits = rest.prefix { $0.isNumber }
        guard let length = Int(digits), length > 0 else {
            return nil
        }
        let name = rest.dropFirst(digits.count).prefix(length)
        return name.count == length ? String(name) : nil
    }

    private static func isSwiftMangled(_ mangled: String) -> Bool {
        mangled.hasPrefix("$s") || mangled.hasPrefix("_$s") || mangled.hasPrefix("$S") || mangled.hasPrefix("_$S") || mangled.hasPrefix("_T")
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

    /// One parsed line of `atos` output: the symbol name it printed, and the file and line when it carried source information.
    private struct AtosLine {
        let name: String?
        let file: String?
        let line: Int?
    }

    #if os(macOS)
        /// Renders mangled names the way the debugger does, through one `swift-demangle -simplified` spawn per report. Returns only the names it could render; a missing tool or a failed spawn leaves every name to the full demangling.
        ///
        /// The simplifier is a toolchain tool, not an OS runtime call: the optioned demangler lives in the toolchain's `libswiftDemangle`, and the OS runtime exports only the plain `swift_demangle`. `xcrun` finds it for the selected toolchain.
        package static func simplifiedNames(forMangled mangled: [String]) -> [String: String] {
            guard mangled.isEmpty == false else {
                return [:]
            }

            // Give the child a completed file rather than feeding a pipe from another GCD block. The caller reads stdout synchronously, so an asynchronous pipe writer would create a forward-progress cycle under a parallel test run: when the global queue has no spare worker, the writer cannot close stdin, swift-demangle cannot exit, and this thread cannot finish reading stdout.
            let input = Data((mangled.joined(separator: "\n") + "\n").utf8)
            let inputURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("exhaust-swift-demangle-\(UUID().uuidString)")
            let inputHandle: FileHandle
            do {
                try input.write(to: inputURL, options: .atomic)
                inputHandle = try FileHandle(forReadingFrom: inputURL)
            } catch {
                try? FileManager.default.removeItem(at: inputURL)
                return [:]
            }
            defer {
                inputHandle.closeFile()
                try? FileManager.default.removeItem(at: inputURL)
            }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            process.arguments = ["swift-demangle", "-simplified"]
            let stdout = Pipe()
            process.standardInput = inputHandle
            process.standardOutput = stdout
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
            } catch {
                return [:]
            }
            let data = stdout.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0, let output = String(data: data, encoding: .utf8) else {
                return [:]
            }
            // One output line per input line, in order; a name the tool could not demangle comes back unchanged.
            let lines = output.split(separator: "\n", omittingEmptySubsequences: false)
            var names: [String: String] = [:]
            for (index, name) in mangled.enumerated() where index < lines.count {
                let simplified = String(lines[index])
                guard simplified.isEmpty == false, simplified != name else {
                    continue
                }
                names[name] = stripSpecialization(simplified)
            }
            return names
        }

        /// Runs `atos` once for one image and parses each address's line: the name before ` (in `, and the file and line when present. Failures leave every address absent.
        private static func sourceLocations(
            image: AtosImage,
            targets: [(edge: Int, programCounter: UInt)]
        ) -> [Int: AtosLine] {
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
                return [:]
            }
            let data = stdout.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0, let output = String(data: data, encoding: .utf8) else {
                return [:]
            }
            // One output line per input address, in order: "name (in Module) (File.swift:123)". An address atos cannot name comes back as the bare address, which is no name. `<stdin>` is what atos reports for a symbol it cannot place; the symbol is real, the file is not.
            var sources: [Int: AtosLine] = [:]
            let lines = output.split(separator: "\n", omittingEmptySubsequences: false)
            for (index, target) in targets.enumerated() where index < lines.count {
                let line = String(lines[index])
                var name: String?
                if let inRange = line.range(of: " (in ") {
                    let candidate = String(line[..<inRange.lowerBound])
                    name = candidate.isEmpty || candidate.hasPrefix("0x") ? nil : candidate
                }
                var file: String?
                var number: Int?
                if let sourceRange = line.range(of: #"\(([^()]+):(\d+)\)\s*$"#, options: .regularExpression) {
                    let source = line[sourceRange].dropFirst().dropLast()
                    if let colon = source.lastIndex(of: ":"), let parsed = Int(source[source.index(after: colon)...]) {
                        let parsedFile = String(source[..<colon])
                        if parsedFile != "<stdin>" {
                            file = parsedFile
                            number = parsed
                        }
                    }
                }
                guard name != nil || file != nil else {
                    continue
                }
                sources[target.edge] = AtosLine(name: name, file: file, line: number)
            }
            return sources
        }
    #endif
}
