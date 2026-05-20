import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

/// Expression macro that expands `#exhaust(Spec.self, .settings...)` into a call to `__runContract(...)` for contract property tests.
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
        let settingsExprs = args.dropFirst(1).map(\.expression.trimmedDescription)
        let settingsArray = settingsExprs.isEmpty ? "[]" : "[\(settingsExprs.joined(separator: ", "))]"

        return """
        __runContract(
            \(raw: specExpr),
            settings: \(raw: settingsArray),
            fileID: #fileID,
            filePath: #filePath,
            line: #line,
            column: #column
        )
        """
    }
}

/// Expression macro that expands `#exhaust(AsyncSpec.self, .settings...)` into a call to `__runContractConcurrent(...)` for async contract property tests with concurrent interleaving.
public struct ExhaustConcurrentContractMacro: ExpressionMacro {
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
        let settingsExprs = args.dropFirst(1).map(\.expression.trimmedDescription)
        let settingsArray = settingsExprs.isEmpty ? "[]" : "[\(settingsExprs.joined(separator: ", "))]"

        return """
        __runContractConcurrent(
            \(raw: specExpr),
            settings: \(raw: settingsArray),
            fileID: #fileID,
            filePath: #filePath,
            line: #line,
            column: #column
        )
        """
    }
}
