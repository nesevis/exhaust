import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

// MARK: - Concurrency Mode Parsing

private enum MacroConcurrencyMode: String {
    case sequential
    case tasks
    case threads

    /// The `ExecutionModel` literal emitted into synthesized code (for example `".sequential"`).
    var executionModelLiteral: String {
        ".\(rawValue)"
    }
}

/// Reads the `ExecutionModel` literal from the `@StateMachine` attribute argument.
///
/// Returns `nil` when the argument is missing or not a recognized literal.
private enum ModeExtractionResult {
    case mode(MacroConcurrencyMode)
    case missing
    case nonLiteral
}

private func extractConcurrencyMode(from node: AttributeSyntax) -> ModeExtractionResult {
    guard let argList = node.arguments?.as(LabeledExprListSyntax.self),
          let firstArg = argList.first
    else {
        return .missing
    }
    guard let memberAccess = firstArg.expression.as(MemberAccessExprSyntax.self) else {
        return .nonLiteral
    }
    if let mode = MacroConcurrencyMode(rawValue: memberAccess.declName.baseName.trimmedDescription) {
        return .mode(mode)
    }
    return .nonLiteral
}

/// The access-control prefix mirrored onto every synthesized member, derived from the spec declaration's own modifiers.
///
/// A `public` (or `open`) spec gets `public` members so the spec is usable from other modules — without this, synthesized members default to internal and a spec cannot be shared between a test target and a benchmark executable. `open` maps to `public` because synthesized members are never override points. Unmodified, `internal`, `fileprivate`, and `private` specs keep the historical unprefixed emission: their members default to internal, which is already at least as visible as the type.
private func accessPrefix(for declaration: some DeclGroupSyntax) -> String {
    let modifierNames = declaration.modifiers.map(\.name.trimmedDescription)
    if modifierNames.contains("public") || modifierNames.contains("open") {
        return "public "
    }
    if modifierNames.contains("package") {
        return "package "
    }
    return ""
}

/// Determines whether the spec needs the `AsyncStateMachineSpec` surface based on its members.
///
/// `.threads` also considers `@Oracle` methods, because the oracle runs inside the async preemptive runner. `.sequential` and `.tasks` only look at commands and invariants.
private func specHasAsyncMember(
    mode: MacroConcurrencyMode,
    commands: [CommandInfo],
    invariants: [InvariantInfo],
    oracles: [OracleInfo],
    setups: [SetupInfo]
) -> Bool {
    let commandsOrInvariants = commands.contains(where: \.isAsync)
        || invariants.contains(where: \.isAsync)
        || setups.contains(where: \.isAsync)
    switch mode {
        case .sequential, .tasks:
            return commandsOrInvariants
        case .threads:
            return commandsOrInvariants || oracles.contains(where: \.isAsync)
    }
}

/// Attached macro that synthesizes spec conformance from a class annotated with `@StateMachine(.sequential)`, `@StateMachine(.tasks)`, or `@StateMachine(.threads)`.
///
/// The mode argument selects the execution model:
/// - `.tasks` — cooperative scheduling of Swift Tasks, checked by `@Invariant`.
/// - `.threads` — preemptive scheduling on real OS threads, checked by `@Oracle`.
///
/// The macro scans for `@SystemUnderTest`, `@Command`, and mode-specific markers, then synthesizes the `Command` enum, `commandGenerator`, `run(_:)`, `checkInvariants()`, and (for `.threads`) `oracleCheck(_:)`.
public struct StateMachineDeclarationMacro: MemberMacro, ExtensionMacro {
    // MARK: - ExtensionMacro

    public static func expansion(
        of node: AttributeSyntax,
        attachedTo declaration: some DeclGroupSyntax,
        providingExtensionsOf type: some TypeSyntaxProtocol,
        conformingTo _: [TypeSyntax],
        in _: some MacroExpansionContext
    ) throws -> [ExtensionDeclSyntax] {
        guard case let .mode(mode) = extractConcurrencyMode(from: node) else {
            return []
        }

        let members = declaration.memberBlock.members
        let commands = extractCommands(from: members)
        let invariants = extractInvariants(from: members)
        let oracles = extractOracles(from: members)
        let setups = extractSetups(from: members)

        let isClassDecl = declaration.is(ClassDeclSyntax.self)
        let isActorDecl = declaration.is(ActorDeclSyntax.self)
        let isReferenceType = isClassDecl || isActorDecl
        guard isReferenceType else {
            return []
        }

        let hasAnyAsync = specHasAsyncMember(mode: mode, commands: commands, invariants: invariants, oracles: oracles, setups: setups)
        let needsAsyncConformance = hasAnyAsync || isActorDecl
        let preconcurrency = isActorDecl ? "@preconcurrency " : ""

        let proto = needsAsyncConformance ? "AsyncStateMachineSpec" : "StateMachineSpec"

        let ext: DeclSyntax = "extension \(type.trimmed): \(raw: preconcurrency)\(raw: proto) {}"
        return [ext.cast(ExtensionDeclSyntax.self)]
    }

    // MARK: - MemberMacro

    public static func expansion(
        of node: AttributeSyntax,
        providingMembersOf declaration: some DeclGroupSyntax,
        conformingTo _: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        let mode: MacroConcurrencyMode
        switch extractConcurrencyMode(from: node) {
            case let .mode(resolved):
                mode = resolved
            case .missing:
                context.diagnose(Diagnostic(
                    node: Syntax(node),
                    message: StateMachineDiagnostic.missingMode
                ))
                return []
            case .nonLiteral:
                context.diagnose(Diagnostic(
                    node: Syntax(node),
                    message: StateMachineDiagnostic.nonLiteralMode
                ))
                return []
        }

        let members = declaration.memberBlock.members

        let sutProps = extractSUTProperties(from: members)
        let commands = extractCommands(from: members)
        let invariants = extractInvariants(from: members)
        let oracles = extractOracles(from: members)
        let setups = extractSetups(from: members)

        let isClassDecl = declaration.is(ClassDeclSyntax.self)
        let isActorDecl = declaration.is(ActorDeclSyntax.self)
        let isReferenceType = isClassDecl || isActorDecl
        let classIsMainActorIsolated = declaration
            .as(ClassDeclSyntax.self)
            .map { hasAttribute("MainActor", on: $0) } ?? false

        // Shared validation
        if isReferenceType == false {
            context.diagnose(Diagnostic(
                node: Syntax(node),
                message: StateMachineDiagnostic.structNotAllowed
            ))
        }
        if commands.isEmpty {
            context.diagnose(Diagnostic(
                node: Syntax(node),
                message: StateMachineDiagnostic.noCommands
            ))
        }
        if sutProps.isEmpty {
            context.diagnose(Diagnostic(
                node: Syntax(node),
                message: StateMachineDiagnostic.noSUT
            ))
        }
        if sutProps.count > 1 {
            context.diagnose(Diagnostic(
                node: Syntax(node),
                message: StateMachineDiagnostic.multipleSUT
            ))
        }

        var seenCommandNames = Set<String>()
        for command in commands {
            let diagnosticNode = command.syntax.map { Syntax($0) } ?? Syntax(node)
            if seenCommandNames.contains(command.methodName) == false {
                seenCommandNames.insert(command.methodName)
            } else {
                context.diagnose(Diagnostic(
                    node: diagnosticNode,
                    message: StateMachineDiagnostic.duplicateCommandName
                ))
            }
            if let value = Int(command.weight), value < 1 {
                context.diagnose(Diagnostic(
                    node: diagnosticNode,
                    message: StateMachineDiagnostic.invalidCommandWeight
                ))
            }
            if let funcDecl = command.syntax {
                if hasUnsupportedParameters(funcDecl) {
                    context.diagnose(Diagnostic(
                        node: diagnosticNode,
                        message: StateMachineDiagnostic.commandHasUnsupportedParameter
                    ))
                }
                if classIsMainActorIsolated || hasAttribute("MainActor", on: funcDecl) {
                    context.diagnose(Diagnostic(
                        node: diagnosticNode,
                        message: StateMachineDiagnostic.mainActorCommand
                    ))
                }
            }
        }

        for invariant in invariants
            where invariant.syntax.signature.parameterClause.parameters.isEmpty == false
        {
            context.diagnose(Diagnostic(
                node: Syntax(invariant.syntax),
                message: StateMachineDiagnostic.invariantHasParameters
            ))
        }

        // Setup validation
        for setup in setups.dropFirst() {
            context.diagnose(Diagnostic(
                node: Syntax(setup.syntax),
                message: StateMachineDiagnostic.multipleSetups
            ))
        }
        for setup in setups {
            let conflictingMarkers = ["Command", "Invariant", "Oracle"]
            if conflictingMarkers.contains(where: { hasAttribute($0, on: setup.syntax) }) {
                context.diagnose(Diagnostic(
                    node: Syntax(setup.syntax),
                    message: StateMachineDiagnostic.setupConflictingMarker
                ))
            }
            if hasUnsupportedParameters(setup.syntax) {
                context.diagnose(Diagnostic(
                    node: Syntax(setup.syntax),
                    message: StateMachineDiagnostic.setupHasUnsupportedParameter
                ))
            }
            if classIsMainActorIsolated || hasAttribute("MainActor", on: setup.syntax) {
                context.diagnose(Diagnostic(
                    node: Syntax(setup.syntax),
                    message: StateMachineDiagnostic.mainActorSetup
                ))
            }
        }

        // Marker methods must be instance methods: every synthesized dispatch goes through the spec instance.
        let markerMethods: [(marker: String, syntax: FunctionDeclSyntax?)] =
            commands.map { ("Command", $0.syntax) }
                + setups.map { ("Setup", $0.syntax) }
                + invariants.map { ("Invariant", $0.syntax) }
                + oracles.map { ("Oracle", $0.syntax) }
        for (marker, syntax) in markerMethods {
            guard let syntax, hasTypeMemberModifier(syntax) else {
                continue
            }
            context.diagnose(Diagnostic(
                node: Syntax(syntax),
                message: TypeMemberMarkerDiagnostic(marker: marker)
            ))
        }

        // Mode-specific validation
        switch mode {
            case .sequential, .tasks:
                if oracles.isEmpty == false {
                    context.diagnose(Diagnostic(
                        node: Syntax(node),
                        message: StateMachineDiagnostic.oracleRequiresThreads
                    ))
                }
                if case .tasks = mode, isActorDecl {
                    context.diagnose(Diagnostic(
                        node: Syntax(node),
                        message: StateMachineDiagnostic.actorRequiresSequential
                    ))
                }
            case .threads:
                if invariants.isEmpty == false {
                    context.diagnose(Diagnostic(
                        node: Syntax(node),
                        message: StateMachineDiagnostic.invariantUnderThreads
                    ))
                }
                let badOracles = oracleMethodsWithWrongParameterCount(from: members)
                for badOracle in badOracles {
                    context.diagnose(Diagnostic(
                        node: Syntax(badOracle),
                        message: StateMachineDiagnostic.oracleParameterCount
                    ))
                }
                if oracles.isEmpty, badOracles.isEmpty {
                    context.diagnose(Diagnostic(
                        node: Syntax(node),
                        message: StateMachineDiagnostic.noOracle
                    ))
                }
                if oracles.count > 1 {
                    context.diagnose(Diagnostic(
                        node: Syntax(node),
                        message: StateMachineDiagnostic.multipleOracles
                    ))
                }
                if isActorDecl {
                    context.diagnose(Diagnostic(
                        node: Syntax(node),
                        message: StateMachineDiagnostic.actorWithThreads
                    ))
                }
                for oracle in oracles where oracle.isThrows {
                    context.diagnose(Diagnostic(
                        node: Syntax(oracle.syntax),
                        message: StateMachineDiagnostic.throwingOracle
                    ))
                }
        }

        let effectiveAsync = specHasAsyncMember(mode: mode, commands: commands, invariants: invariants, oracles: oracles, setups: setups)
            || isActorDecl

        let access = accessPrefix(for: declaration)

        var decls: [DeclSyntax] = []

        decls.append(synthesizeCommandEnum(commands: commands, access: access))

        if let sutProp = sutProps.first, let sutType = sutProp.type {
            decls.append("\(raw: access)typealias SystemUnderTest = \(raw: typealiasCompatibleType(sutType))")
            decls.append("\(raw: access)var systemUnderTest: SystemUnderTest { \(raw: sutProp.name) }")
        } else if sutProps.first != nil {
            context.diagnose(Diagnostic(
                node: Syntax(node),
                message: StateMachineDiagnostic.sutTypeNotInferred
            ))
            decls.append("\(raw: access)var systemUnderTest: Never { fatalError(\"SUT type could not be inferred — add an explicit type annotation to the @SystemUnderTest property\") }")
        }

        decls.append(synthesizeCommandGenerator(commands: commands, access: access, context: context))
        decls.append(synthesizeRunMethod(commands: commands, hasAnyAsync: effectiveAsync, access: access))
        decls.append(synthesizeCheckInvariants(invariants: invariants, hasAnyAsync: effectiveAsync, access: access))

        if let setup = setups.first {
            decls.append(synthesizeSetupEnum(setup: setup, access: access))
            decls.append(synthesizeSetupGenerator(setup: setup, access: access, context: context))
            decls.append(synthesizeRunSetup(setup: setup, hasAnyAsync: effectiveAsync, access: access))
        }

        if mode == .threads, let oracle = oracles.first {
            decls.append(synthesizeOracleCheck(oracle: oracle, hasAnyAsync: effectiveAsync, access: access))
        }

        decls.append("\(raw: access)static let executionModel: ExecutionModel = \(raw: mode.executionModelLiteral)")

        if isActorDecl {
            decls.append("""
            \(raw: access)func diagnosticSnapshot() async -> DiagnosticSnapshot<SystemUnderTest> {
                DiagnosticSnapshot(systemUnderTest: systemUnderTest, failureDescription: failureDescription())
            }
            """)
        }

        let hasUserInit = members.contains { member in
            guard let initDecl = member.decl.as(InitializerDeclSyntax.self) else { return false }
            return initDecl.signature.parameterClause.parameters.isEmpty
                && initDecl.optionalMark == nil
        }
        if isReferenceType, hasUserInit == false {
            if isClassDecl {
                decls.append("\(raw: access)required init() {}")
            } else if isActorDecl {
                decls.append("\(raw: access)init() {}")
            }
        }

        return decls
    }
}
