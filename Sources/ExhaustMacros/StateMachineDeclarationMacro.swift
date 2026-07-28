import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

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
/// Every marked member counts, the equivalence included: the mode is chosen at the call site now, so the macro cannot know which runner will call which member and has to serve whichever asks. A spec whose every member is synchronous keeps the synchronous surface, which is what lets the sequential runner run it without bridging.
private func specHasAsyncMember(
    commands: [CommandInfo],
    invariants: [InvariantInfo],
    equivalences: [EquivalenceInfo],
    setups: [SetupInfo]
) -> Bool {
    commands.contains(where: \.isAsync)
        || invariants.contains(where: \.isAsync)
        || setups.contains(where: \.isAsync)
        || equivalences.contains(where: \.isAsync)
}

/// Attached macro that synthesizes spec conformance from a class annotated with `@StateMachine`.
///
/// One spec shape serves every execution mode, because the mode is a `#execute` argument rather than a property of the declaration. The macro scans for `@SystemUnderTest`, `@Command`, `@Invariant`, `@Setup`, and `@Equivalence`, then synthesizes the `Command` enum, `commandGenerator`, `run(_:)`, `checkInvariants()`, and, when an equivalence is declared, `equivalenceCheck(_:)` and `hasEquivalence`.
///
/// What a mode requires of a spec is therefore checked where the mode is known, at the start of a run: a thread-based run needs an equivalence and a reference-typed system under test, and says so with a runtime error naming the call site.
public struct StateMachineDeclarationMacro: MemberMacro, ExtensionMacro {
    // MARK: - ExtensionMacro

    public static func expansion(
        of _: AttributeSyntax,
        attachedTo declaration: some DeclGroupSyntax,
        providingExtensionsOf type: some TypeSyntaxProtocol,
        conformingTo _: [TypeSyntax],
        in _: some MacroExpansionContext
    ) throws -> [ExtensionDeclSyntax] {
        let members = declaration.memberBlock.members
        let commands = extractCommands(from: members)
        let invariants = extractInvariants(from: members)
        let equivalences = extractEquivalences(from: members)
        let setups = extractSetups(from: members)

        guard declaration.is(ClassDeclSyntax.self) else {
            return []
        }

        let hasAnyAsync = specHasAsyncMember(commands: commands, invariants: invariants, equivalences: equivalences, setups: setups)
        let proto = hasAnyAsync ? "AsyncStateMachineSpec" : "StateMachineSpec"

        let ext: DeclSyntax = "extension \(type.trimmed): \(raw: proto) {}"
        return [ext.cast(ExtensionDeclSyntax.self)]
    }

    // MARK: - MemberMacro

    public static func expansion(
        of node: AttributeSyntax,
        providingMembersOf declaration: some DeclGroupSyntax,
        conformingTo _: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        let members = declaration.memberBlock.members

        let sutProps = extractSUTProperties(from: members)
        let commands = extractCommands(from: members)
        let invariants = extractInvariants(from: members)
        let equivalences = extractEquivalences(from: members)
        let setups = extractSetups(from: members)

        let isClassDecl = declaration.is(ClassDeclSyntax.self)
        let isActorDecl = declaration.is(ActorDeclSyntax.self)
        let classIsMainActorIsolated = declaration
            .as(ClassDeclSyntax.self)
            .map { hasAttribute("MainActor", on: $0) } ?? false

        // Shared validation
        if isActorDecl {
            context.diagnose(Diagnostic(
                node: Syntax(node),
                message: StateMachineDiagnostic.actorNotAllowed
            ))
        } else if isClassDecl == false {
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
        // A spec is judged through one of four channels: an invariant after every command, an equivalence, an error thrown out of a command body (`check(_:_:)` is the usual one), or an error thrown out of setup — `applySetup(_:)` hands that error back to the runner rather than rethrowing it, and every runner turns it into a failed sequence. Declaring none of them leaves the synthesized invariant check empty and nothing else to consult, so every sequence passes. Methods are checked for `throws` rather than for a `check` call, because any thrown error fails the sequence.
        if commands.isEmpty == false,
           invariants.isEmpty,
           equivalences.isEmpty,
           setups.contains(where: \.isThrows) == false,
           commands.contains(where: \.isThrows) == false
        {
            context.diagnose(Diagnostic(
                node: Syntax(node),
                message: StateMachineDiagnostic.specCannotFail
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
            let conflictingMarkers = ["Command", "Invariant", "Equivalence"]
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
                + equivalences.map { ("Equivalence", $0.syntax) }
        for (marker, syntax) in markerMethods {
            guard let syntax, hasTypeMemberModifier(syntax) else {
                continue
            }
            context.diagnose(Diagnostic(
                node: Syntax(syntax),
                message: TypeMemberMarkerDiagnostic(marker: marker)
            ))
        }

        // Equivalence validation. What a mode demands of a spec is checked at the start of a run, where the mode is known; what the method itself must look like is checked here, where the method is.
        let badEquivalences = equivalenceMethodsWithWrongParameterCount(from: members)
        for badEquivalence in badEquivalences {
            context.diagnose(Diagnostic(
                node: Syntax(badEquivalence),
                message: StateMachineDiagnostic.equivalenceParameterCount
            ))
        }
        if equivalences.count > 1 {
            context.diagnose(Diagnostic(
                node: Syntax(node),
                message: StateMachineDiagnostic.multipleEquivalences
            ))
        }
        for equivalence in equivalences where equivalence.isThrows {
            context.diagnose(Diagnostic(
                node: Syntax(equivalence.syntax),
                message: StateMachineDiagnostic.throwingEquivalence
            ))
        }

        let effectiveAsync = specHasAsyncMember(commands: commands, invariants: invariants, equivalences: equivalences, setups: setups)

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

        if let equivalence = equivalences.first {
            decls.append(synthesizeEquivalenceCheck(equivalence: equivalence, hasAnyAsync: effectiveAsync, access: access))
            // Announced rather than inferred: a runner cannot ask a spec whether it declared one, and the default `equivalenceCheck` traps, so the flag is what keeps a concurrent run from calling into it.
            decls.append("\(raw: access)static let hasEquivalence: Bool = true")
        }

        let hasUserInit = members.contains { member in
            guard let initDecl = member.decl.as(InitializerDeclSyntax.self) else { return false }
            return initDecl.signature.parameterClause.parameters.isEmpty
                && initDecl.optionalMark == nil
        }
        if isClassDecl, hasUserInit == false {
            decls.append("\(raw: access)required init() {}")
        }

        return decls
    }
}
