import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxMacros

/// Expression macro that expands `#examine(gen)` or `#examine(gen, samples: N, seed: S)` into
/// a call to `__ExhaustRuntime.__examine(...)`.
public struct ExamineMacro: ExpressionMacro {
    public static func expansion(
        of node: some FreestandingMacroExpansionSyntax,
        in context: some MacroExpansionContext,
    ) throws -> ExprSyntax {
        let args = node.arguments.map(\.self)

        guard !args.isEmpty else {
            context.diagnose(Diagnostic(
                node: Syntax(node),
                message: ExhaustMacroDiagnostic.examineMissingGenerator,
            ))
            return "fatalError(\"#examine requires a generator argument\")"
        }

        let generatorExpr = args[0].expression.trimmedDescription

        let samplesArg = args.first { $0.label?.text == "samples" }
        let seedArg = args.first { $0.label?.text == "seed" }

        let samplesExpr = samplesArg?.expression.trimmedDescription ?? "200"
        let seedExpr = seedArg?.expression.trimmedDescription ?? "nil"

        return """
        __ExhaustRuntime.__examine(
            \(raw: generatorExpr),
            samples: \(raw: samplesExpr),
            seed: \(raw: seedExpr),
            fileID: #fileID,
            filePath: #filePath,
            line: #line,
            column: #column
        )
        """
    }
}
