import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

/// Expression macro that expands `#exhaust(Spec.self, commandLimit: N, .settings...)` into a call to `__runContract(...)` for contract property tests.
///
/// When `commandLimit:` is omitted, the expansion passes `nil` and the runtime estimates a default from the command generator's structure.
public struct ExhaustContractMacro: ExpressionMacro {
    public static func expansion(
        of node: some FreestandingMacroExpansionSyntax,
        in context: some MacroExpansionContext
    ) throws -> ExprSyntax {
        let args = node.arguments.map(\.self)

        guard args.count >= 1 else {
            context.diagnose(Diagnostic(
                node: Syntax(node),
                message: ExhaustMacroDiagnostic.exhaustContractMissingSpec
            ))
            return "fatalError(\"#exhaust requires a spec type argument\")"
        }

        let specExpr = args[0].expression.trimmedDescription
        let (commandLimitExpr, settingsStart) = extractCommandLimit(from: args)
        let settingsExprs = args.dropFirst(settingsStart).map(\.expression.trimmedDescription)
        let settingsArray = settingsExprs.isEmpty ? "[]" : "[\(settingsExprs.joined(separator: ", "))]"

        return """
        __runContract(
            \(raw: specExpr),
            commandLimit: \(raw: commandLimitExpr),
            settings: \(raw: settingsArray),
            fileID: #fileID,
            filePath: #filePath,
            line: #line,
            column: #column
        )
        """
    }
}

/// Expression macro that expands `#exhaust(AsyncSpec.self, commandLimit: N, .settings...)` into a call to `__runContractAsync(...)` for async contract property tests.
///
/// When `commandLimit:` is omitted, the expansion passes `nil` and the runtime estimates a default from the command generator's structure.
public struct ExhaustAsyncContractMacro: ExpressionMacro {
    public static func expansion(
        of node: some FreestandingMacroExpansionSyntax,
        in context: some MacroExpansionContext
    ) throws -> ExprSyntax {
        let args = node.arguments.map(\.self)

        guard args.count >= 1 else {
            context.diagnose(Diagnostic(
                node: Syntax(node),
                message: ExhaustMacroDiagnostic.exhaustContractMissingSpec
            ))
            return "fatalError(\"#exhaust requires a spec type argument\")"
        }

        let specExpr = args[0].expression.trimmedDescription
        let (commandLimitExpr, settingsStart) = extractCommandLimit(from: args)
        let settingsExprs = args.dropFirst(settingsStart).map(\.expression.trimmedDescription)
        let settingsArray = settingsExprs.isEmpty ? "[]" : "[\(settingsExprs.joined(separator: ", "))]"

        return """
        __runContractAsync(
            \(raw: specExpr),
            commandLimit: \(raw: commandLimitExpr),
            settings: \(raw: settingsArray),
            fileID: #fileID,
            filePath: #filePath,
            line: #line,
            column: #column
        )
        """
    }
}

// MARK: - Helpers

private func extractCommandLimit(
    from args: [LabeledExprListSyntax.Element]
) -> (expression: String, settingsStartIndex: Int) {
    if args.count >= 2, args[1].label?.text == "commandLimit" {
        return (args[1].expression.trimmedDescription, 2)
    }
    return ("nil", 1)
}
