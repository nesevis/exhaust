import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

/// Expression macro that expands `#exhaust(Spec.self, .settings...)` into a call to `__runStateMachine(...)` for state-machine property tests.
public struct ExhaustStateMachineMacro: ExpressionMacro {
    public static func expansion(
        of node: some FreestandingMacroExpansionSyntax,
        in context: some MacroExpansionContext,
    ) throws -> ExprSyntax {
        let args = node.arguments.map(\.self)

        guard !args.isEmpty else {
            context.diagnose(Diagnostic(
                node: Syntax(node),
                message: ExhaustMacroDiagnostic.exhaustStateMachineMissingSpec,
            ))
            return "fatalError(\"#exhaust requires a spec type argument\")"
        }

        let specExpr = args[0].expression.trimmedDescription
        let settingsExprs = args.dropFirst().map(\.expression.trimmedDescription)
        let settingsArray = settingsExprs.isEmpty ? "[]" : "[\(settingsExprs.joined(separator: ", "))]"

        return """
        __runStateMachine(
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
