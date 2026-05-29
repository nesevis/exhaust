import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

/// Attached macro that synthesizes `ContractSpec` conformance from a struct annotated with `@Contract`.
///
/// Scans the struct for `@Model`, `@SystemUnderTest`, `@Command`, and `@Invariant` annotations, then generates:
/// - A `Command` enum with one case per `@Command` method.
/// - A `commandGenerator` static property using `Gen.pick`.
/// - A `run(_:)` method dispatching commands to their methods.
/// - A `checkInvariants()` method calling all `@Invariant` methods.
/// - `modelDescription` and `sutDescription` computed properties.
public struct ContractDeclarationMacro: MemberMacro, ExtensionMacro {
    // MARK: - ExtensionMacro

    public static func expansion(
        of node: AttributeSyntax,
        attachedTo declaration: some DeclGroupSyntax,
        providingExtensionsOf type: some TypeSyntaxProtocol,
        conformingTo _: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [ExtensionDeclSyntax] {
        let members = declaration.memberBlock.members
        let commands = extractCommands(from: members)
        let invariants = extractInvariants(from: members)
        let hasAnyAsync =
            commands.contains(where: \.isAsync)
                || invariants.contains(where: \.isAsync)

        let isClassDecl = declaration.is(ClassDeclSyntax.self)
        if hasAnyAsync, isClassDecl == false {
            context.diagnose(Diagnostic(
                node: Syntax(node),
                message: ContractDiagnostic.asyncRequiresClass
            ))
        }

        let proto = hasAnyAsync ? "AsyncContractSpec" : "ContractSpec"
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

        let modelProps = extractModelProperties(from: members)
        let sutProps = extractSUTProperties(from: members)
        let commands = extractCommands(from: members)
        let invariants = extractInvariants(from: members)

        // Validate
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

        let hasAnyAsync =
            commands.contains(where: \.isAsync)
                || invariants.contains(where: \.isAsync)

        var decls: [DeclSyntax] = []

        // 1. Command enum
        decls.append(synthesizeCommandEnum(commands: commands))

        // 2. SystemUnderTest typealias + systemUnderTest accessor
        if let sutProp = sutProps.first, let sutType = sutProp.type {
            decls.append("typealias SystemUnderTest = \(raw: sutType)")
            decls.append("var systemUnderTest: SystemUnderTest { \(raw: sutProp.name) }")
        } else if sutProps.first != nil {
            // No type available — use Never as a placeholder and emit a note.
            // The compiler will produce a type mismatch if the user accesses .systemUnderTest, which is better than a confusing "could not infer" error.
            context.diagnose(Diagnostic(
                node: Syntax(node),
                message: ContractDiagnostic.sutTypeNotInferred
            ))
            decls.append("var systemUnderTest: Never { fatalError(\"SUT type could not be inferred — add an explicit type annotation to the @SystemUnderTest property\") }")
        }

        // 3. commandGenerator
        decls.append(synthesizeCommandGenerator(commands: commands, context: context))

        // 4. run(_:)
        let isClassDecl = declaration.is(ClassDeclSyntax.self)
        decls.append(synthesizeRunMethod(commands: commands, hasAnyAsync: hasAnyAsync, isClassDecl: isClassDecl))

        // 5. checkInvariants()
        decls.append(synthesizeCheckInvariants(invariants: invariants, hasAnyAsync: hasAnyAsync))

        // 6. modelDescription
        decls.append(synthesizeModelDescription(modelProps: modelProps))

        // 7. sutDescription
        decls.append(synthesizeSUTDescription(sutProps: sutProps))

        // 8. required init() for classes (satisfies ContractSpecBase.init())
        let hasUserInit = members.contains { member in
            guard let initDecl = member.decl.as(InitializerDeclSyntax.self) else { return false }
            return initDecl.signature.parameterClause.parameters.isEmpty
        }
        if isClassDecl, hasUserInit == false {
            decls.append("required init() {}")
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

func extractModelProperties(from members: MemberBlockItemListSyntax) -> [String] {
    members.compactMap { member in
        guard let varDecl = member.decl.as(VariableDeclSyntax.self),
              hasAttribute("Model", on: varDecl)
        else { return nil }
        return varDecl.bindings.first?.pattern.trimmedDescription
    }
}

struct SUTProperty {
    let name: String
    let type: String?
}

func extractSUTProperties(from members: MemberBlockItemListSyntax) -> [SUTProperty] {
    members.compactMap { member in
        guard let varDecl = member.decl.as(VariableDeclSyntax.self),
              hasAttribute("SystemUnderTest", on: varDecl),
              let binding = varDecl.bindings.first
        else { return nil }

        let name = binding.pattern.trimmedDescription

        // Try explicit type annotation first: `@SystemUnderTest var queue: BoundedQueue<Int>`
        if let typeAnnotation = binding.typeAnnotation {
            return SUTProperty(name: name, type: typeAnnotation.type.trimmedDescription)
        }

        // Fall back to inferring from initializer: `@SystemUnderTest var queue = BoundedQueue<Int>(capacity: 3)` or `@SystemUnderTest var stack = [Int]()`.
        // Only when the callee is plausibly a type. A factory expression like `makeQueue()` has a non-type callee, so returning it would emit `typealias SystemUnderTest = makeQueue`; instead fall through to nil so the `sutTypeNotInferred` warning tells the user to annotate.
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
                } else if let macroExpr = arg.expression.as(MacroExpansionExprSyntax.self),
                          macroExpr.macroName.trimmedDescription == "gen",
                          macroExpr.trailingClosure == nil
                {
                    // #gen(.a, .b) without trailing closure — unwrap inner generator arguments
                    for innerArg in macroExpr.arguments {
                        generatorExprs.append(innerArg.expression.trimmedDescription)
                    }
                } else {
                    // Unlabeled arguments are generator expressions
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

func synthesizeRunMethod(commands: [CommandInfo], hasAnyAsync: Bool, isClassDecl: Bool) -> DeclSyntax {
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
    let mutatingKeyword = isClassDecl ? "" : "mutating "
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

func synthesizeModelDescription(modelProps: [String]) -> DeclSyntax {
    if modelProps.isEmpty {
        return """
        var modelDescription: String { "(no model properties)" }
        """
    }

    if modelProps.count == 1 {
        let part = "\"\(modelProps[0]): \\(\(modelProps[0]))\""
        return """
        var modelDescription: String { \(raw: part) }
        """
    }

    let lines = modelProps.map { "\"  \($0): \\(\($0))\"" }.joined(separator: ",\n            ")
    return """
    var modelDescription: String { "\\n" + [
            \(raw: lines)
        ].joined(separator: "\\n") }
    """
}

func synthesizeSUTDescription(sutProps: [SUTProperty]) -> DeclSyntax {
    if sutProps.isEmpty {
        return """
        var sutDescription: String { "(no SUT)" }
        """
    }

    let parts = sutProps.map { "\"\($0.name): \\(\($0.name))\"" }.joined(separator: " + \", \" + ")

    return """
    var sutDescription: String { \(raw: parts) }
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

// MARK: - Diagnostics

enum ContractDiagnostic: String, DiagnosticMessage {
    case noCommands = "@Contract requires at least one @Command method"
    case noSUT = "@Contract requires exactly one @SystemUnderTest property"
    case multipleSUT = "@Contract requires exactly one @SystemUnderTest property, but multiple were found"
    case sutTypeNotInferred = "@SystemUnderTest property type could not be inferred — add an explicit type annotation"
    case commandMissingGenerators = "@Command method has parameters but no generator expressions — add generators to the @Command attribute"
    case asyncRequiresClass = "@Contract with async commands or invariants must be a class — use 'final class' instead of 'struct'"

    var message: String {
        rawValue
    }

    var diagnosticID: MessageID {
        MessageID(domain: "ExhaustMacros", id: "\(self)")
    }

    var severity: DiagnosticSeverity {
        switch self {
            case .noCommands, .noSUT, .multipleSUT, .commandMissingGenerators, .asyncRequiresClass: .error
            case .sutTypeNotInferred: .warning
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
