import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

/// Expression macro that expands `#exhaust(Spec.self, commandLimit: N, .settings...)` into a call to `__runContract(...)` for contract property tests.
public struct ExhaustContractMacro: ExpressionMacro {
    public static func expansion(
        of node: some FreestandingMacroExpansionSyntax,
        in context: some MacroExpansionContext
    ) throws -> ExprSyntax {
        let args = node.arguments.map(\.self)

        guard args.count >= 2 else {
            context.diagnose(Diagnostic(
                node: Syntax(node),
                message: ExhaustMacroDiagnostic.exhaustContractMissingSpec
            ))
            return "fatalError(\"#exhaust requires a spec type and commandLimit argument\")"
        }

        let specExpr = args[0].expression.trimmedDescription
        let commandLimitExpr = args[1].expression.trimmedDescription
        let settingsExprs = args.dropFirst(2).map(\.expression.trimmedDescription)
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
public struct ExhaustAsyncContractMacro: ExpressionMacro {
    public static func expansion(
        of node: some FreestandingMacroExpansionSyntax,
        in context: some MacroExpansionContext
    ) throws -> ExprSyntax {
        let args = node.arguments.map(\.self)

        guard args.count >= 2 else {
            context.diagnose(Diagnostic(
                node: Syntax(node),
                message: ExhaustMacroDiagnostic.exhaustContractMissingSpec
            ))
            return "fatalError(\"#exhaust requires a spec type and commandLimit argument\")"
        }

        let specExpr = args[0].expression.trimmedDescription
        let commandLimitExpr = args[1].expression.trimmedDescription
        let settingsExprs = args.dropFirst(2).map(\.expression.trimmedDescription)
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
