import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxMacros

/// Expression macro that expands `#sample(gen)` or `#sample(gen, count: N)` into
/// a call to `__ExhaustRuntime.__sample(...)` or `__ExhaustRuntime.__sampleArray(...)`.
public struct SampleMacro: ExpressionMacro {
    public static func expansion(
        of node: some FreestandingMacroExpansionSyntax,
        in context: some MacroExpansionContext,
    ) throws -> ExprSyntax {
        let args = node.arguments.map(\.self)

        guard !args.isEmpty else {
            context.diagnose(Diagnostic(
                node: Syntax(node),
                message: ExhaustMacroDiagnostic.sampleMissingGenerator,
            ))
            return "fatalError(\"#sample requires a generator argument\")"
        }

        let generatorExpr = args[0].expression.trimmedDescription

        let countArg = args.first { $0.label?.text == "count" }
        let seedArg = args.first { $0.label?.text == "seed" }

        let seedExpr = seedArg?.expression.trimmedDescription ?? "nil"

        if let countArg {
            let countExpr = countArg.expression.trimmedDescription
            return """
            __ExhaustRuntime.__sampleArray(
                \(raw: generatorExpr),
                count: \(raw: countExpr),
                seed: \(raw: seedExpr)
            )
            """
        } else {
            return """
            __ExhaustRuntime.__sample(
                \(raw: generatorExpr),
                seed: \(raw: seedExpr)
            )
            """
        }
    }
}
