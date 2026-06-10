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

/// Reads the `ExecutionModel` literal from the `@Contract` attribute argument.
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

/// Determines whether the contract needs the `AsyncContractSpec` surface based on its members.
///
/// `.threads` also considers `@Oracle` methods, because the oracle runs inside the async preemptive runner. `.sequential` and `.tasks` only look at commands and invariants.
private func contractHasAsyncMember(
    mode: MacroConcurrencyMode,
    commands: [CommandInfo],
    invariants: [InvariantInfo],
    oracles: [OracleInfo]
) -> Bool {
    let commandsOrInvariants = commands.contains(where: \.isAsync) || invariants.contains(where: \.isAsync)
    switch mode {
        case .sequential, .tasks:
            return commandsOrInvariants
        case .threads:
            return commandsOrInvariants || oracles.contains(where: \.isAsync)
    }
}

/// Attached macro that synthesizes contract conformance from a class annotated with `@Contract(.sequential)`, `@Contract(.tasks)`, or `@Contract(.threads)`.
///
/// The mode argument selects the execution model:
/// - `.tasks` — cooperative scheduling of Swift Tasks, checked by `@Invariant`.
/// - `.threads` — preemptive scheduling on real OS threads, checked by `@Oracle`.
///
/// The macro scans for `@SystemUnderTest`, `@Command`, and mode-specific markers, then synthesizes the `Command` enum, `commandGenerator`, `run(_:)`, `checkInvariants()`, and (for `.threads`) `oracleCheck(_:)`.
public struct ContractDeclarationMacro: MemberMacro, ExtensionMacro {
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

        let isClassDecl = declaration.is(ClassDeclSyntax.self)
        let isActorDecl = declaration.is(ActorDeclSyntax.self)
        let isReferenceType = isClassDecl || isActorDecl

        guard isReferenceType else {
            return []
        }

        let hasAnyAsync = contractHasAsyncMember(mode: mode, commands: commands, invariants: invariants, oracles: oracles)
        let needsAsyncConformance = hasAnyAsync || isActorDecl
        let preconcurrency = isActorDecl ? "@preconcurrency " : ""

        let proto = needsAsyncConformance ? "AsyncContractSpec" : "ContractSpec"

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
                    message: ContractDiagnostic.missingMode
                ))
                return []
            case .nonLiteral:
                context.diagnose(Diagnostic(
                    node: Syntax(node),
                    message: ContractDiagnostic.nonLiteralMode
                ))
                return []
        }

        let members = declaration.memberBlock.members

        let sutProps = extractSUTProperties(from: members)
        let commands = extractCommands(from: members)
        let invariants = extractInvariants(from: members)
        let oracles = extractOracles(from: members)

        let isClassDecl = declaration.is(ClassDeclSyntax.self)
        let isActorDecl = declaration.is(ActorDeclSyntax.self)
        let isReferenceType = isClassDecl || isActorDecl

        // Shared validation
        if isReferenceType == false {
            context.diagnose(Diagnostic(
                node: Syntax(node),
                message: ContractDiagnostic.structNotAllowed
            ))
        }
        if commands.isEmpty {
            context.diagnose(Diagnostic(
                node: Syntax(node),
                message: ContractDiagnostic.noCommands
            ))
        }
        if sutProps.isEmpty {
            context.diagnose(Diagnostic(
                node: Syntax(node),
                message: ContractDiagnostic.noSUT
            ))
        }
        if sutProps.count > 1 {
            context.diagnose(Diagnostic(
                node: Syntax(node),
                message: ContractDiagnostic.multipleSUT
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
                    message: ContractDiagnostic.duplicateCommandName
                ))
            }
            if let value = Int(command.weight), value < 1 {
                context.diagnose(Diagnostic(
                    node: diagnosticNode,
                    message: ContractDiagnostic.invalidCommandWeight
                ))
            }
            if let funcDecl = command.syntax {
                let hasGenericParams = funcDecl.genericParameterClause != nil
                let hasInoutParam = funcDecl.signature.parameterClause.parameters.contains {
                    $0.type.as(AttributedTypeSyntax.self)?.specifiers.contains { $0.trimmedDescription == "inout" } ?? false
                }
                let hasVariadicParam = funcDecl.signature.parameterClause.parameters.contains {
                    $0.ellipsis != nil
                }
                if hasGenericParams || hasInoutParam || hasVariadicParam {
                    context.diagnose(Diagnostic(
                        node: diagnosticNode,
                        message: ContractDiagnostic.commandHasUnsupportedParameter
                    ))
                }
            }
        }

        // Mode-specific validation
        switch mode {
            case .sequential, .tasks:
                if oracles.isEmpty == false {
                    context.diagnose(Diagnostic(
                        node: Syntax(node),
                        message: ContractDiagnostic.oracleRequiresThreads
                    ))
                }
                if case .tasks = mode, isActorDecl {
                    context.diagnose(Diagnostic(
                        node: Syntax(node),
                        message: ContractDiagnostic.actorRequiresSequential
                    ))
                }
            case .threads:
                if invariants.isEmpty == false {
                    context.diagnose(Diagnostic(
                        node: Syntax(node),
                        message: ContractDiagnostic.invariantUnderThreads
                    ))
                }
                let badOracles = oracleMethodsWithWrongParameterCount(from: members)
                for badOracle in badOracles {
                    context.diagnose(Diagnostic(
                        node: Syntax(badOracle),
                        message: ContractDiagnostic.oracleParameterCount
                    ))
                }
                if oracles.isEmpty, badOracles.isEmpty {
                    context.diagnose(Diagnostic(
                        node: Syntax(node),
                        message: ContractDiagnostic.noOracle
                    ))
                }
                if oracles.count > 1 {
                    context.diagnose(Diagnostic(
                        node: Syntax(node),
                        message: ContractDiagnostic.multipleOracles
                    ))
                }
                if isActorDecl {
                    context.diagnose(Diagnostic(
                        node: Syntax(node),
                        message: ContractDiagnostic.actorWithThreads
                    ))
                }
        }

        let effectiveAsync = contractHasAsyncMember(mode: mode, commands: commands, invariants: invariants, oracles: oracles)
            || isActorDecl

        var decls: [DeclSyntax] = []

        decls.append(synthesizeCommandEnum(commands: commands))

        if let sutProp = sutProps.first, let sutType = sutProp.type {
            decls.append("typealias SystemUnderTest = \(raw: sutType)")
            decls.append("var systemUnderTest: SystemUnderTest { \(raw: sutProp.name) }")
        } else if sutProps.first != nil {
            context.diagnose(Diagnostic(
                node: Syntax(node),
                message: ContractDiagnostic.sutTypeNotInferred
            ))
            decls.append("var systemUnderTest: Never { fatalError(\"SUT type could not be inferred — add an explicit type annotation to the @SystemUnderTest property\") }")
        }

        decls.append(synthesizeCommandGenerator(commands: commands, context: context))
        decls.append(synthesizeRunMethod(commands: commands, hasAnyAsync: effectiveAsync, isReferenceType: true))
        decls.append(synthesizeCheckInvariants(invariants: invariants, hasAnyAsync: effectiveAsync))
        let hasUserFailureDescription = members.contains { member in
            guard let funcDecl = member.decl.as(FunctionDeclSyntax.self) else { return false }
            return funcDecl.name.trimmedDescription == "failureDescription"
                && funcDecl.signature.parameterClause.parameters.isEmpty
        }
        if hasUserFailureDescription == false {
            decls.append(synthesizeFailureDescription(sutProps: sutProps))
        }

        if mode == .threads, let oracle = oracles.first {
            decls.append(synthesizeOracleCheck(oracle: oracle, hasAnyAsync: effectiveAsync))
        }

        decls.append("static let executionModel: ExecutionModel = \(raw: mode.executionModelLiteral)")

        if isActorDecl {
            decls.append("""
            func diagnosticSnapshot() async -> DiagnosticSnapshot<SystemUnderTest> {
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
                decls.append("required init() {}")
            } else if isActorDecl {
                decls.append("init() {}")
            }
        }

        return decls
    }
}

// MARK: - Extraction

struct CommandInfo {
    let methodName: String
    let parameters: [CommandParameter]
    let weight: String
    let generatorExprs: [String]
    let isAsync: Bool
    let isThrows: Bool
    let syntax: FunctionDeclSyntax?
}

/// One parameter of a `@Command` method, splitting the external argument label from the internal binding name.
///
/// A parameter like `func push(_ value: Int)` has no external label (`firstName` is `_`) but a usable binding name (`value`). Reusing the raw `_` as a value expression produces illegal synthesized code, so the two roles are tracked separately.
struct CommandParameter {
    /// External argument label at the call site, or `nil` when the parameter is unlabeled (source `firstName` is `_`).
    let externalLabel: String?
    /// Identifier for the synthesized enum associated value, pattern binding, and value expression. Never `_` — synthesized as `arg{index}` when the source parameter has no usable internal name.
    let bindingName: String
    /// The parameter's type, used for generator qualification and the enum associated-value declaration.
    let type: String
}

struct InvariantInfo {
    let methodName: String
    let isAsync: Bool
}

struct SUTProperty {
    let name: String
    let type: String?
}

func extractSUTProperties(from members: MemberBlockItemListSyntax) -> [SUTProperty] {
    members.flatMap { member -> [SUTProperty] in
        guard let varDecl = member.decl.as(VariableDeclSyntax.self),
              hasAttribute("SystemUnderTest", on: varDecl)
        else { return [] }

        return varDecl.bindings.map { binding in
            let name = binding.pattern.trimmedDescription

            if let typeAnnotation = binding.typeAnnotation {
                return SUTProperty(name: name, type: typeAnnotation.type.trimmedDescription)
            }

            if let initializer = binding.initializer,
               let call = initializer.value.as(FunctionCallExprSyntax.self)
            {
                let callee = call.calledExpression.trimmedDescription
                if isPlausiblyTypeName(callee) {
                    return SUTProperty(name: name, type: callee)
                }
            }

            return SUTProperty(name: name, type: nil)
        }
    }
}

func extractCommands(from members: MemberBlockItemListSyntax) -> [CommandInfo] {
    members.compactMap { member in
        guard let funcDecl = member.decl.as(FunctionDeclSyntax.self),
              let commandAttr = findAttribute("Command", on: funcDecl)
        else { return nil }

        let methodName = funcDecl.name.trimmedDescription
        let parameters = funcDecl.signature.parameterClause.parameters.enumerated().map { index, param in
            let firstName = param.firstName.trimmedDescription
            let secondName = param.secondName?.trimmedDescription
            let externalLabel = firstName == "_" ? nil : firstName
            let rawBinding = secondName ?? firstName
            let bindingName = rawBinding == "_" ? "arg\(index)" : rawBinding
            return CommandParameter(
                externalLabel: externalLabel,
                bindingName: bindingName,
                type: param.type.trimmedDescription
            )
        }

        // Extract weight and generator expressions from @Command(weight:, #gen(...))
        var weight = "1"
        var generatorExprs: [String] = []

        if let argList = commandAttr.arguments?.as(LabeledExprListSyntax.self) {
            for arg in argList {
                if arg.label?.trimmedDescription == "weight" {
                    weight = arg.expression.trimmedDescription
                } else {
                    generatorExprs.append(arg.expression.trimmedDescription)
                }
            }
        }

        let isAsync = funcDecl.signature.effectSpecifiers?.asyncSpecifier != nil
        let isThrows = funcDecl.signature.effectSpecifiers?.throwsClause != nil

        return CommandInfo(
            methodName: methodName,
            parameters: parameters,
            weight: weight,
            generatorExprs: generatorExprs,
            isAsync: isAsync,
            isThrows: isThrows,
            syntax: funcDecl
        )
    }
}

func extractInvariants(from members: MemberBlockItemListSyntax) -> [InvariantInfo] {
    members.compactMap { member in
        guard let funcDecl = member.decl.as(FunctionDeclSyntax.self),
              hasAttribute("Invariant", on: funcDecl)
        else { return nil }
        let isAsync = funcDecl.signature.effectSpecifiers?.asyncSpecifier != nil
        return InvariantInfo(methodName: funcDecl.name.trimmedDescription, isAsync: isAsync)
    }
}

func hasAttribute(_ name: String, on decl: some WithAttributesSyntax) -> Bool {
    decl.attributes.contains { attr in
        attr.as(AttributeSyntax.self)?.attributeName.trimmedDescription == name
    }
}

func findAttribute(_ name: String, on decl: some WithAttributesSyntax) -> AttributeSyntax? {
    decl.attributes.compactMap { attr in
        attr.as(AttributeSyntax.self)
    }.first { $0.attributeName.trimmedDescription == name }
}

// MARK: - Synthesis

func synthesizeCommandEnum(commands: [CommandInfo]) -> DeclSyntax {
    var cases: [String] = []
    var descriptionCases: [String] = []

    for cmd in commands {
        if cmd.parameters.isEmpty {
            cases.append("        case \(cmd.methodName)")
            descriptionCases.append("            case .\(cmd.methodName): \"\(cmd.methodName)\"")
        } else {
            let assocValues = cmd.parameters.map {
                "\($0.bindingName): \($0.type)"
            }.joined(separator: ", ")
            cases.append("        case \(cmd.methodName)(\(assocValues))")

            let bindings = cmd.parameters.map(\.bindingName).joined(separator: ", ")
            let formatParts = cmd.parameters.map { "\\(\($0.bindingName))" }.joined(separator: ", ")
            descriptionCases.append("            case let .\(cmd.methodName)(\(bindings)): \"\(cmd.methodName)(\(formatParts))\"")
        }
    }

    let casesBlock = cases.joined(separator: "\n")
    let descriptionBlock = descriptionCases.joined(separator: "\n")

    return """
    enum Command: CustomStringConvertible, Sendable {
    \(raw: casesBlock)

        var description: String {
            switch self {
    \(raw: descriptionBlock)
            }
        }
    }
    """
}

func synthesizeCommandGenerator(commands: [CommandInfo], context: some MacroExpansionContext) -> DeclSyntax {
    var choices: [String] = []

    for cmd in commands {
        if cmd.parameters.isEmpty {
            choices.append("            (\(cmd.weight), .just(Command.\(cmd.methodName)))")
            continue
        }

        // A parameterized command needs exactly one generator per parameter. Without this check, `zip` truncation silently emits a `#gen` whose arity disagrees with the closure (compile error) or drops extra generators (wrong behavior), with no diagnostic.
        guard cmd.generatorExprs.count == cmd.parameters.count else {
            if let syntax = cmd.syntax {
                let message: DiagnosticMessage = cmd.generatorExprs.isEmpty
                    ? ContractDiagnostic.commandMissingGenerators
                    : CommandGeneratorArityDiagnostic(
                        parameterCount: cmd.parameters.count,
                        generatorCount: cmd.generatorExprs.count
                    )
                context.diagnose(Diagnostic(node: Syntax(syntax), message: message))
            }
            choices.append("            (\(cmd.weight), .just(Command.\(cmd.methodName)))")
            continue
        }

        if cmd.parameters.count == 1 {
            // Single parameter — use #gen for bidirectional enum case mapping
            let param = cmd.parameters[0]
            let genExpr = qualifyGenExpression(cmd.generatorExprs[0], paramType: param.type)
            choices.append("            (\(cmd.weight), #gen(\(genExpr)) { \(param.bindingName) in Command.\(cmd.methodName)(\(param.bindingName): \(param.bindingName)) })")
        } else {
            // Multiple parameters — #gen with zip (counts are equal, guaranteed above)
            let qualifiedGens = zip(cmd.generatorExprs, cmd.parameters).map {
                qualifyGenExpression($0.0, paramType: $0.1.type)
            }
            let genArgs = qualifiedGens.joined(separator: ", ")
            let closureParams = cmd.parameters.map(\.bindingName).joined(separator: ", ")
            let constructorArgs = cmd.parameters.map {
                "\($0.bindingName): \($0.bindingName)"
            }.joined(separator: ", ")
            choices.append("            (\(cmd.weight), #gen(\(genArgs)) { \(closureParams) in Command.\(cmd.methodName)(\(constructorArgs)) })")
        }
    }

    let choicesBlock = choices.joined(separator: ",\n")

    return """
    static var commandGenerator: ReflectiveGenerator<Command> {
        .oneOf(weighted:
    \(raw: choicesBlock)
        )
    }
    """
}

func synthesizeRunMethod(commands: [CommandInfo], hasAnyAsync: Bool, isReferenceType: Bool) -> DeclSyntax {
    var cases: [String] = []

    for cmd in commands {
        let effectKeywords: String
        switch (cmd.isThrows, cmd.isAsync) {
            case (true, true): effectKeywords = "try await "
            case (true, false): effectKeywords = "try "
            case (false, true): effectKeywords = "await "
            case (false, false): effectKeywords = ""
        }
        if cmd.parameters.isEmpty {
            cases.append("        case .\(cmd.methodName): \(effectKeywords)self.\(cmd.methodName)()")
        } else {
            let bindings = cmd.parameters.map(\.bindingName).joined(separator: ", ")
            // The call into the user's method uses the external argument label (omitted when the parameter is unlabeled); the value is always the binding name.
            let args = cmd.parameters.map { param in
                param.externalLabel.map { "\($0): \(param.bindingName)" } ?? param.bindingName
            }.joined(separator: ", ")
            cases.append("        case let .\(cmd.methodName)(\(bindings)): \(effectKeywords)self.\(cmd.methodName)(\(args))")
        }
    }

    let casesBlock = cases.joined(separator: "\n")
    let mutatingKeyword = isReferenceType ? "" : "mutating "
    let signature = hasAnyAsync
        ? "\(mutatingKeyword)func run(_ command: Command) async throws"
        : "\(mutatingKeyword)func run(_ command: Command) throws"

    return """
    \(raw: signature) {
        switch command {
    \(raw: casesBlock)
        }
    }
    """
}

func synthesizeCheckInvariants(
    invariants: [InvariantInfo],
    hasAnyAsync: Bool
) -> DeclSyntax {
    let signature = hasAnyAsync
        ? "func checkInvariants() async throws"
        : "func checkInvariants() throws"

    if invariants.isEmpty {
        return """
        \(raw: signature) {}
        """
    }

    var checks: [String] = []
    for inv in invariants {
        if hasAnyAsync, inv.isAsync {
            // Evaluate async invariant before passing to check() since @autoclosure doesn't support async.
            checks.append("        let \(inv.methodName)Result = await \(inv.methodName)()")
            checks.append("        try check(\(inv.methodName)Result, \"\(inv.methodName)\")")
        } else {
            checks.append("        try check(\(inv.methodName)(), \"\(inv.methodName)\")")
        }
    }
    let checksBlock = checks.joined(separator: "\n")

    return """
    \(raw: signature) {
    \(raw: checksBlock)
    }
    """
}

func synthesizeFailureDescription(sutProps: [SUTProperty]) -> DeclSyntax {
    if let sut = sutProps.first {
        return """
        func failureDescription() -> String { "\\(\(raw: sut.name))" }
        """
    }

    return """
    func failureDescription() -> String { "(no SUT)" }
    """
}

/// Wraps a generator expression with a type cast to provide type context for implicit member syntax.
///
/// User writes `@Command(weight: 3, .int(in: 0...9))` — the expression `.int(in: 0...9)` has no base type in the synthesized context. Casting to `ReflectiveGenerator<ParamType>` resolves the member lookup.
func qualifyGenExpression(_ expr: String, paramType: String) -> String {
    if expr.hasPrefix(".") {
        return "(\(expr) as ReflectiveGenerator<\(paramType)>)"
    }
    return expr
}

/// Whether an initializer's callee expression is plausibly a type name (so it can back a `typealias`), as opposed to a factory function.
///
/// Array and dictionary sugar (`[Int]`, `[Key: Value]`) qualifies. Otherwise the final dot-separated component must begin with an uppercase character — `BoundedQueue<Int>` and `Module.Queue` qualify; `makeQueue` and `factory.make` do not.
func isPlausiblyTypeName(_ expression: String) -> Bool {
    if expression.hasPrefix("[") { return true }
    let lastComponent = expression.split(separator: ".").last.map(String.init) ?? expression
    return lastComponent.first?.isUppercase ?? false
}

// MARK: - Oracle Extraction and Synthesis

struct OracleInfo {
    let methodName: String
    let parameterLabel: String
    let parameterType: String
    let isAsync: Bool
}

func extractOracles(from members: MemberBlockItemListSyntax) -> [OracleInfo] {
    members.compactMap { member in
        guard let funcDecl = member.decl.as(FunctionDeclSyntax.self),
              hasAttribute("Oracle", on: funcDecl)
        else { return nil }
        let params = funcDecl.signature.parameterClause.parameters
        guard params.count == 1, let firstParam = params.first else { return nil }
        let isAsync = funcDecl.signature.effectSpecifiers?.asyncSpecifier != nil
        return OracleInfo(
            methodName: funcDecl.name.trimmedDescription,
            parameterLabel: firstParam.firstName.trimmedDescription,
            parameterType: firstParam.type.trimmedDescription,
            isAsync: isAsync
        )
    }
}

func oracleMethodsWithWrongParameterCount(from members: MemberBlockItemListSyntax) -> [FunctionDeclSyntax] {
    members.compactMap { member in
        guard let funcDecl = member.decl.as(FunctionDeclSyntax.self),
              hasAttribute("Oracle", on: funcDecl)
        else { return nil }
        let paramCount = funcDecl.signature.parameterClause.parameters.count
        return paramCount == 1 ? nil : funcDecl
    }
}

func synthesizeOracleCheck(oracle: OracleInfo, hasAnyAsync: Bool) -> DeclSyntax {
    let signature = hasAnyAsync
        ? "func oracleCheck(_ sequentialResult: SystemUnderTest) async -> Bool"
        : "func oracleCheck(_ sequentialResult: SystemUnderTest) -> Bool"
    let awaitKeyword = oracle.isAsync ? "await " : ""
    let callArgument = oracle.parameterLabel == "_"
        ? "sequentialResult"
        : "\(oracle.parameterLabel): sequentialResult"
    return """
    \(raw: signature) {
        \(raw: awaitKeyword)\(raw: oracle.methodName)(\(raw: callArgument))
    }
    """
}

// MARK: - Diagnostics

enum ContractDiagnostic: String, DiagnosticMessage {
    case noCommands = "@Contract requires at least one @Command method"
    case noSUT = "@Contract requires exactly one @SystemUnderTest property"
    case multipleSUT = "@Contract requires exactly one @SystemUnderTest property, but multiple were found"
    case sutTypeNotInferred = "@SystemUnderTest property type could not be inferred — add an explicit type annotation"
    case commandMissingGenerators = "@Command method has parameters but no generator expressions — add generators to the @Command attribute"
    case structNotAllowed = "Contract specs must be a 'final class' or 'actor' — structs are not supported"
    case missingMode = "@Contract requires an execution mode: @Contract(.sequential|.tasks|.threads)"
    case nonLiteralMode = "The execution mode must be a literal ExecutionModel case (.sequential|.tasks|.threads)"
    case oracleRequiresThreads = "@Oracle is only used with @Contract(.threads). For @Contract(.sequential) or @Contract(.tasks), use @Invariant instead"
    case invariantUnderThreads = "@Invariant requires deterministic per-step state, which a preemptive run does not have. Use @Contract(.tasks)"
    case noOracle = "@Contract(.threads) requires exactly one @Oracle method"
    case multipleOracles = "@Contract(.threads) allows only one @Oracle method"
    case actorRequiresSequential = "Actor contracts must use @Contract(.sequential). Actor isolation serializes all dispatch, so concurrent testing has nowhere to interleave"
    case actorWithThreads = "Actor contracts must use @Contract(.sequential). Actors are data-race-free, so .threads cannot surface races in them"
    case duplicateCommandName = "Two @Command methods share the same base name — rename one or merge them"
    case invalidCommandWeight = "@Command weight must be a positive integer literal"
    case oracleParameterCount = "@Oracle must take exactly one parameter of the SystemUnderTest type"
    case commandHasUnsupportedParameter = "@Command parameters must not be inout, variadic, or generic — the synthesized Command enum cannot represent them"

    var message: String {
        rawValue
    }

    var diagnosticID: MessageID {
        MessageID(domain: "ExhaustMacros", id: "\(self)")
    }

    var severity: DiagnosticSeverity {
        switch self {
            case .noCommands, .noSUT, .multipleSUT, .sutTypeNotInferred, .commandMissingGenerators,
                 .structNotAllowed, .missingMode, .nonLiteralMode, .noOracle, .multipleOracles,
                 .actorRequiresSequential, .actorWithThreads,
                 .duplicateCommandName, .invalidCommandWeight, .oracleParameterCount,
                 .commandHasUnsupportedParameter:
                .error
            case .oracleRequiresThreads, .invariantUnderThreads:
                .warning
        }
    }
}

/// Diagnostic for a `@Command` whose generator count does not match its parameter count.
///
/// Carries both counts so the message names the exact mismatch rather than a generic "wrong generators" note.
struct CommandGeneratorArityDiagnostic: DiagnosticMessage {
    let parameterCount: Int
    let generatorCount: Int

    var message: String {
        "@Command has \(parameterCount) parameter\(parameterCount == 1 ? "" : "s") but \(generatorCount) generator\(generatorCount == 1 ? "" : "s") — provide exactly one generator per parameter"
    }

    var diagnosticID: MessageID {
        MessageID(domain: "ExhaustMacros", id: "commandGeneratorArityMismatch")
    }

    var severity: DiagnosticSeverity {
        .error
    }
}
