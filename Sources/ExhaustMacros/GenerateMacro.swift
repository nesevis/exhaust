import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

/// Expression macro that transforms `#generate(gen1, gen2, ...) { params in Body(...) }`
/// into a `ReflectiveGenerator` with automatic backward mapping when possible.
///
/// When the closure body is a struct/class initializer call with labeled arguments
/// that correspond 1:1 to the closure parameters, a `.mapped(forward:backward:)` call
/// is emitted. Otherwise, falls back to `.map` with a warning diagnostic.
public struct GenerateMacro: ExpressionMacro {
    public static func expansion(
        of node: some FreestandingMacroExpansionSyntax,
        in context: some MacroExpansionContext
    ) throws -> ExprSyntax {
        // Separate generator arguments from the trailing closure
        guard let trailingClosure = node.trailingClosure else {
            context.diagnose(Diagnostic(
                node: Syntax(node),
                message: ExhaustMacroDiagnostic.missingTrailingClosure
            ))
            return "fatalError(\"#generate requires a trailing closure\")"
        }

        let generatorArgs = node.arguments.map { $0 }
        guard !generatorArgs.isEmpty else {
            context.diagnose(Diagnostic(
                node: Syntax(node),
                message: ExhaustMacroDiagnostic.noGeneratorArguments
            ))
            return "fatalError(\"#generate requires at least one generator argument\")"
        }

        let generatorCount = generatorArgs.count
        let outcome = analyzeClosureForBidirectional(trailingClosure, generatorCount: generatorCount)

        switch outcome {
        case let .bidirectional(result):
            return buildBidirectionalExpansion(
                generatorArgs: generatorArgs,
                closure: trailingClosure,
                result: result
            )
        case let .forwardOnly(diagnostic):
            context.diagnose(Diagnostic(
                node: Syntax(trailingClosure),
                message: diagnostic
            ))
            return buildForwardOnlyExpansion(
                generatorArgs: generatorArgs,
                closure: trailingClosure
            )
        }
    }

    /// Builds the expansion for a bidirectional (forward + backward) mapping.
    private static func buildBidirectionalExpansion(
        generatorArgs: [LabeledExprListSyntax.Element],
        closure: ClosureExprSyntax,
        result: BidirectionalResult
    ) -> ExprSyntax {
        let closureText = closure.trimmedDescription

        if generatorArgs.count == 1 {
            // Single generator: gen.mapped(forward: closure, backward: { $0.label })
            let genExpr = generatorArgs[0].expression.trimmedDescription
            let label = result.labels[0]
            return "\(raw: genExpr).mapped(forward: \(raw: closureText), backward: { $0.\(raw: label) })"
        } else {
            // Multi generator: Gen.zip(g1, g2).mapped(forward: { ... }, backward: { ... })
            let genExprs = generatorArgs.map { $0.expression.trimmedDescription }
            let zipArgs = genExprs.joined(separator: ", ")

            // Build the backward closure ordered by parameter position.
            // Gen.zip produces a tuple in parameter (generator) order, so the backward
            // mapping must return components in that same order.
            let backwardComponents = buildBackwardComponents(result: result)
            let backwardBody = backwardComponents.joined(separator: ", ")

            return "Gen.zip(\(raw: zipArgs)).mapped(forward: \(raw: closureText), backward: { (\(raw: backwardBody)) })"
        }
    }

    /// Builds backward mapping components ordered by parameter position.
    ///
    /// The closure parameters may appear in a different order than the initializer arguments.
    /// For example: `{ age, name in Person(name: name, age: age) }`
    /// - Parameters (generator order): [age, name]
    /// - Arguments: [name: name, age: age]
    /// - argumentParamRefs: [name, age] (which param was passed at each arg position)
    ///
    /// The backward tuple must match parameter order: `($0.age, $0.name)`
    /// For each parameter, find the argument position where it was used, and use that label.
    private static func buildBackwardComponents(result: BidirectionalResult) -> [String] {
        // Build a map from parameter name → the label it was passed as
        var paramToLabel: [String: String] = [:]
        for (argIndex, paramRef) in result.argumentParamRefs.enumerated() {
            paramToLabel[paramRef] = result.labels[argIndex]
        }

        // Return labels in parameter order (which is generator/tuple order)
        return result.parameterNames.map { paramName in
            "$0.\(paramToLabel[paramName]!)"
        }
    }

    /// Builds the expansion for a forward-only mapping (no backward).
    private static func buildForwardOnlyExpansion(
        generatorArgs: [LabeledExprListSyntax.Element],
        closure: ClosureExprSyntax
    ) -> ExprSyntax {
        let closureText = closure.trimmedDescription

        if generatorArgs.count == 1 {
            let genExpr = generatorArgs[0].expression.trimmedDescription
            return "\(raw: genExpr).map \(raw: closureText)"
        } else {
            let genExprs = generatorArgs.map { $0.expression.trimmedDescription }
            let zipArgs = genExprs.joined(separator: ", ")
            return "Gen.zip(\(raw: zipArgs)).map \(raw: closureText)"
        }
    }
}
