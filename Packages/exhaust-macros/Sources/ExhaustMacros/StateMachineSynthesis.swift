import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

// MARK: - Synthesis

/// Returns `preferredName`, suffixed until it no longer collides with any name a synthesized `case let` pattern binds.
///
/// The dispatch method's subject variable is in scope alongside the case bindings, so a spec whose parameter is literally named `command` or `step` would otherwise shadow it.
func availableLocalName(_ preferredName: String, avoiding parameterBindingNames: Set<String>) -> String {
    var candidateName = preferredName
    while parameterBindingNames.contains(candidateName) {
        candidateName += "Value"
    }
    return candidateName
}

/// The `switch` case pattern and the call expression that dispatch one annotated method.
///
/// Shared by the command and setup dispatch synthesis so the two cannot drift on effect-keyword ordering or argument labelling.
func dispatchCase(
    methodName: String,
    parameters: [CommandParameter],
    isThrows: Bool,
    isAsync: Bool
) -> (pattern: String, call: String) {
    let effectKeywords = switch (isThrows, isAsync) {
        case (true, true):
            "try await "
        case (true, false):
            "try "
        case (false, true):
            "await "
        case (false, false):
            ""
    }

    guard parameters.isEmpty == false else {
        return (pattern: "case .\(methodName)", call: "\(effectKeywords)self.\(methodName)()")
    }

    let bindings = parameters.map(\.bindingName).joined(separator: ", ")
    let arguments = parameters.map { parameter in
        parameter.externalLabel.map { "\($0): \(parameter.bindingName)" }
            ?? parameter.bindingName
    }.joined(separator: ", ")
    return (
        pattern: "case let .\(methodName)(\(bindings))",
        call: "\(effectKeywords)self.\(methodName)(\(arguments))"
    )
}

func synthesizeCommandEnum(commands: [CommandInfo], access: String) -> DeclSyntax {
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
    \(raw: access)enum Command: CustomStringConvertible, Sendable {
    \(raw: casesBlock)

        \(raw: access)var description: String {
            switch self {
    \(raw: descriptionBlock)
            }
        }
    }
    """
}

func synthesizeCommandGenerator(commands: [CommandInfo], access: String, context: some MacroExpansionContext) -> DeclSyntax {
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
                    ? StateMachineDiagnostic.commandMissingGenerators
                    : GeneratorArityDiagnostic(
                        marker: .command,
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
    \(raw: access)static var commandGenerator: ReflectiveGenerator<Command> {
        .oneOf(weighted:
    \(raw: choicesBlock)
        )
    }
    """
}

func synthesizeRunMethod(commands: [CommandInfo], hasAnyAsync: Bool, access: String) -> DeclSyntax {
    let parameterBindingNames = Set(
        commands.flatMap { commandInfo in
            commandInfo.parameters.map(\.bindingName)
        }
    )
    let commandVariableName = availableLocalName("command", avoiding: parameterBindingNames)
    let resultVariableName = availableLocalName("result", avoiding: parameterBindingNames)
    var cases: [String] = []

    for commandInfo in commands {
        let (pattern, call) = dispatchCase(
            methodName: commandInfo.methodName,
            parameters: commandInfo.parameters,
            isThrows: commandInfo.isThrows,
            isAsync: commandInfo.isAsync
        )

        if let returnType = commandInfo.returnType {
            let isOptional = returnType.hasSuffix("?") || returnType.hasPrefix("Optional<")
            let returnExpression = isOptional
                ? #"\#(resultVariableName) ?? "nil" as Any"#
                : resultVariableName
            cases.append(
                """
                        \(pattern):
                            let \(resultVariableName) = \(call)
                            return CommandResponse(commandDescription: \(commandVariableName).description, returnValue: \(returnExpression))
                """
            )
        } else {
            cases.append(
                """
                        \(pattern):
                            \(call)
                            return CommandResponse(commandDescription: \(commandVariableName).description, returnValue: nil)
                """
            )
        }
    }

    let casesBlock = cases.joined(separator: "\n")
    let signature = hasAnyAsync
        ? "@discardableResult \(access)func run(_ \(commandVariableName): Command) async throws -> CommandResponse"
        : "@discardableResult \(access)func run(_ \(commandVariableName): Command) throws -> CommandResponse"

    return """
    \(raw: signature) {
        switch \(raw: commandVariableName) {
    \(raw: casesBlock)
        }
    }
    """
}

func synthesizeCheckInvariants(
    invariants: [InvariantInfo],
    hasAnyAsync: Bool,
    access: String
) -> DeclSyntax {
    let signature = hasAnyAsync
        ? "\(access)func checkInvariants() async throws"
        : "\(access)func checkInvariants() throws"

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

// MARK: - Setup Synthesis

func synthesizeSetupEnum(setup: SetupInfo, access: String) -> DeclSyntax {
    let caseDecl: String
    let descriptionCase: String

    if setup.parameters.isEmpty {
        caseDecl = "    case \(setup.methodName)"
        descriptionCase = "            case .\(setup.methodName): \"\(setup.methodName)\""
    } else {
        let assocValues = setup.parameters.map {
            "\($0.bindingName): \($0.type)"
        }.joined(separator: ", ")
        caseDecl = "    case \(setup.methodName)(\(assocValues))"

        let bindings = setup.parameters.map(\.bindingName).joined(separator: ", ")
        let formatParts = setup.parameters.map { "\($0.bindingName): \\(\($0.bindingName))" }.joined(separator: ", ")
        descriptionCase = "            case let .\(setup.methodName)(\(bindings)): \"\(setup.methodName)(\(formatParts))\""
    }

    return """
    \(raw: access)enum SetupStep: CustomStringConvertible, Sendable {
    \(raw: caseDecl)

        \(raw: access)var description: String {
            switch self {
    \(raw: descriptionCase)
            }
        }
    }
    """
}

func synthesizeSetupGenerator(setup: SetupInfo, access: String, context: some MacroExpansionContext) -> DeclSyntax {
    let body: String

    if setup.parameters.isEmpty {
        body = "(.just(SetupStep.\(setup.methodName)) as ReflectiveGenerator<SetupStep>)"
    } else if setup.generatorExprs.count != setup.parameters.count {
        // A parameterized setup needs exactly one generator per parameter, exactly as commands do. Fall back to nil so the spec still compiles alongside the diagnostic.
        let message: DiagnosticMessage = setup.generatorExprs.isEmpty
            ? StateMachineDiagnostic.setupMissingGenerators
            : GeneratorArityDiagnostic(
                marker: .setup,
                parameterCount: setup.parameters.count,
                generatorCount: setup.generatorExprs.count
            )
        context.diagnose(Diagnostic(node: Syntax(setup.syntax), message: message))
        body = "nil"
    } else {
        let qualifiedGens = zip(setup.generatorExprs, setup.parameters).map {
            qualifyGenExpression($0.0, paramType: $0.1.type)
        }
        let genArgs = qualifiedGens.joined(separator: ", ")
        let closureParams = setup.parameters.map(\.bindingName).joined(separator: ", ")
        let constructorArgs = setup.parameters.map {
            "\($0.bindingName): \($0.bindingName)"
        }.joined(separator: ", ")
        body = "#gen(\(genArgs)) { \(closureParams) in SetupStep.\(setup.methodName)(\(constructorArgs)) }"
    }

    return """
    \(raw: access)static var setupGenerator: ReflectiveGenerator<SetupStep>? {
        \(raw: body)
    }
    """
}

func synthesizeRunSetup(setup: SetupInfo, hasAnyAsync: Bool, access: String) -> DeclSyntax {
    let stepVariableName = availableLocalName("step", avoiding: Set(setup.parameters.map(\.bindingName)))
    let (pattern, call) = dispatchCase(
        methodName: setup.methodName,
        parameters: setup.parameters,
        isThrows: setup.isThrows,
        isAsync: setup.isAsync
    )

    let discard = setup.returnType != nil ? "_ = " : ""
    let signature = hasAnyAsync
        ? "\(access)func runSetup(_ \(stepVariableName): SetupStep) async throws"
        : "\(access)func runSetup(_ \(stepVariableName): SetupStep) throws"

    return """
    \(raw: signature) {
        switch \(raw: stepVariableName) {
            \(raw: pattern):
                \(raw: discard)\(raw: call)
        }
    }
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

/// Rewrites an implicitly unwrapped type annotation (`Foo!`) to its optional spelling for use in a `typealias`.
///
/// Swift only allows the `!` suffix on variable, parameter, and return declarations — `typealias SystemUnderTest = Foo!` is rejected with "using '!' is not allowed here". The stored property keeps its implicitly unwrapped type; only the synthesized alias changes, and the `systemUnderTest` accessor returning `Foo?` from an implicitly unwrapped property compiles as-is.
func typealiasCompatibleType(_ type: String) -> String {
    guard type.hasSuffix("!") else {
        return type
    }
    return String(type.dropLast()) + "?"
}

/// Whether an initializer's callee expression is plausibly a type name (so it can back a `typealias`), as opposed to a factory function.
///
/// Array and dictionary sugar (`[Int]`, `[Key: Value]`) qualifies. Otherwise the final dot-separated component must begin with an uppercase character — `BoundedQueue<Int>` and `Module.Queue` qualify; `makeQueue` and `factory.make` do not.
func isPlausiblyTypeName(_ expression: String) -> Bool {
    if expression.hasPrefix("[") { return true }
    let lastComponent = expression.split(separator: ".").last.map(String.init) ?? expression
    return lastComponent.first?.isUppercase ?? false
}

func synthesizeEquivalenceCheck(equivalence: EquivalenceInfo, hasAnyAsync: Bool, access: String) -> DeclSyntax {
    let signature = hasAnyAsync
        ? "\(access)func equivalenceCheck(_ sequentialResult: SystemUnderTest) async -> Bool"
        : "\(access)func equivalenceCheck(_ sequentialResult: SystemUnderTest) -> Bool"
    let awaitKeyword = equivalence.isAsync ? "await " : ""
    let callArgument = equivalence.parameterLabel == "_"
        ? "sequentialResult"
        : "\(equivalence.parameterLabel): sequentialResult"
    return """
    \(raw: signature) {
        \(raw: awaitKeyword)\(raw: equivalence.methodName)(\(raw: callArgument))
    }
    """
}
