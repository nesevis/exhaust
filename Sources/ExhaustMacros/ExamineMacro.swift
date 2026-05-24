import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxMacros

/// Expression macro that expands `#examine(gen, .settings...)` into a call to `__ExhaustRuntime.__examine(...)`.
public struct ExamineMacro: ExpressionMacro {
    public static func expansion(
        of node: some FreestandingMacroExpansionSyntax,
        in context: some MacroExpansionContext
    ) throws -> ExprSyntax {
        let args = node.arguments.map(\.self)

        guard args.isEmpty == false else {
            context.diagnose(Diagnostic(
                node: Syntax(node),
                message: ExhaustMacroDiagnostic.examineMissingGenerator
            ))
            return "fatalError(\"#examine requires a generator argument\")"
        }

        let generatorExpr = args[0].expression.trimmedDescription

        var settingsExprs: [String] = []
        for arg in args.dropFirst() {
            settingsExprs.append(arg.expression.trimmedDescription)
        }
        let settingsArray = settingsExprs.isEmpty
            ? "[]"
            : "[\(settingsExprs.joined(separator: ", "))]"

        return """
        __ExhaustRuntime.__examine(
            \(raw: generatorExpr),
            settings: \(raw: settingsArray),
            fileID: #fileID,
            filePath: #filePath,
            line: #line,
            column: #column
        )
        """
    }
}
