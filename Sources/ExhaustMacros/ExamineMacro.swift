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
        var replayCheckExpr: String?
        for arg in args.dropFirst() {
            if arg.label?.text == "replayCheck" {
                replayCheckExpr = arg.expression.trimmedDescription
            } else {
                settingsExprs.append(arg.expression.trimmedDescription)
            }
        }

        if replayCheckExpr == nil, let trailingClosure = node.trailingClosure {
            replayCheckExpr = trailingClosure.trimmedDescription
        }

        let settingsArray = settingsExprs.isEmpty
            ? "[]"
            : "[\(settingsExprs.joined(separator: ", "))]"

        if let replayCheckExpr {
            return """
            __ExhaustRuntime.__examine(
                \(raw: generatorExpr),
                settings: \(raw: settingsArray),
                replayCheck: \(raw: replayCheckExpr),
                fileID: #fileID,
                filePath: #filePath,
                line: #line,
                column: #column
            )
            """
        }

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
