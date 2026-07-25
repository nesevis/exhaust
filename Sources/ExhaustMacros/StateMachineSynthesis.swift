import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

// MARK: - Synthesis

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

    func availableLocalName(preferredName: String) -> String {
        var candidateName = preferredName
        while parameterBindingNames.contains(candidateName) {
            candidateName += "Value"
        }
        return candidateName
    }

    let commandVariableName = availableLocalName(preferredName: "command")
    let resultVariableName = availableLocalName(preferredName: "result")
    var cases: [String] = []

    for commandInfo in commands {
        let effectKeywords: String
        switch (commandInfo.isThrows, commandInfo.isAsync) {
            case (true, true): effectKeywords = "try await "
            case (true, false): effectKeywords = "try "
            case (false, true): effectKeywords = "await "
            case (false, false): effectKeywords = ""
        }

        let call: String
        let pattern: String
        if commandInfo.parameters.isEmpty {
            call = "\(effectKeywords)self.\(commandInfo.methodName)()"
            pattern = "case .\(commandInfo.methodName)"
        } else {
            let bindings = commandInfo.parameters.map(\.bindingName).joined(separator: ", ")
            let arguments = commandInfo.parameters.map { parameter in
                parameter.externalLabel.map { "\($0): \(parameter.bindingName)" }
                    ?? parameter.bindingName
            }.joined(separator: ", ")
            call = "\(effectKeywords)self.\(commandInfo.methodName)(\(arguments))"
            pattern = "case let .\(commandInfo.methodName)(\(bindings))"
        }

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
            : SetupGeneratorArityDiagnostic(
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
    let parameterBindingNames = Set(setup.parameters.map(\.bindingName))

    func availableLocalName(preferredName: String) -> String {
        var candidateName = preferredName
        while parameterBindingNames.contains(candidateName) {
            candidateName += "Value"
        }
        return candidateName
    }

    let stepVariableName = availableLocalName(preferredName: "step")

    let effectKeywords: String
    switch (setup.isThrows, setup.isAsync) {
        case (true, true): effectKeywords = "try await "
        case (true, false): effectKeywords = "try "
        case (false, true): effectKeywords = "await "
        case (false, false): effectKeywords = ""
    }

    let call: String
    let pattern: String
    if setup.parameters.isEmpty {
        call = "\(effectKeywords)self.\(setup.methodName)()"
        pattern = "case .\(setup.methodName)"
    } else {
        let bindings = setup.parameters.map(\.bindingName).joined(separator: ", ")
        let arguments = setup.parameters.map { parameter in
            parameter.externalLabel.map { "\($0): \(parameter.bindingName)" }
                ?? parameter.bindingName
        }.joined(separator: ", ")
        call = "\(effectKeywords)self.\(setup.methodName)(\(arguments))"
        pattern = "case let .\(setup.methodName)(\(bindings))"
    }

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

/// Whether an initializer's callee expression is plausibly a type name (so it can back a `typealias`), as opposed to a factory function.
///
/// Array and dictionary sugar (`[Int]`, `[Key: Value]`) qualifies. Otherwise the final dot-separated component must begin with an uppercase character — `BoundedQueue<Int>` and `Module.Queue` qualify; `makeQueue` and `factory.make` do not.
func isPlausiblyTypeName(_ expression: String) -> Bool {
    if expression.hasPrefix("[") { return true }
    let lastComponent = expression.split(separator: ".").last.map(String.init) ?? expression
    return lastComponent.first?.isUppercase ?? false
}

func synthesizeOracleCheck(oracle: OracleInfo, hasAnyAsync: Bool, access: String) -> DeclSyntax {
    let signature = hasAnyAsync
        ? "\(access)func oracleCheck(_ sequentialResult: SystemUnderTest) async -> Bool"
        : "\(access)func oracleCheck(_ sequentialResult: SystemUnderTest) -> Bool"
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
