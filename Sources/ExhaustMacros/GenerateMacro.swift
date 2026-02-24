import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

/// Expression macro that transforms `#gen(gen1, gen2, ...) { params in Body(...) }`
/// into a `ReflectiveGenerator` with automatic backward mapping when possible.
///
/// When the closure body is a struct/class initializer call with labeled arguments
/// that correspond 1:1 to the closure parameters, a Mirror-based backward mapping
/// is synthesized, producing a fully bidirectional generator. This works regardless
/// of property access control since Mirror ignores visibility.
///
/// When backward inference is not possible (complex expressions, shorthand parameters,
/// multi-statement bodies), the macro falls back to a forward-only `.map` with a warning.
public struct GenerateMacro: ExpressionMacro {
    public static func expansion(
        of node: some FreestandingMacroExpansionSyntax,
        in context: some MacroExpansionContext
    ) throws -> ExprSyntax {
        let generatorArgs = node.arguments.map { $0 }
        guard !generatorArgs.isEmpty else {
            context.diagnose(Diagnostic(
                node: Syntax(node),
                message: ExhaustMacroDiagnostic.noGeneratorArguments
            ))
            return "fatalError(\"#gen requires at least one generator argument\")"
        }

        // No trailing closure — zip-only overload
        guard let trailingClosure = node.trailingClosure else {
            return buildZipExpansion(generatorArgs: generatorArgs)
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
        case .forwardOnly:
            return buildForwardOnlyExpansion(
                generatorArgs: generatorArgs,
                closure: trailingClosure
            )
        }
    }

    /// Builds the expansion for a bidirectional mapping using Mirror-based backward extraction.
    ///
    /// Single generator: uses `Gen.contramap` with `_mirrorExtract` applied to a `.map`.
    /// Multi generator: uses `Gen._macroZip` which combines zip + Mirror backward
    /// internally, avoiding the tuple type mismatch that `zip().mapped()` would cause.
    private static func buildBidirectionalExpansion(
        generatorArgs: [LabeledExprListSyntax.Element],
        closure: ClosureExprSyntax,
        result: BidirectionalResult
    ) -> ExprSyntax {
        let closureText = closure.trimmedDescription

        if generatorArgs.count == 1 {
            let genExpr = generatorArgs[0].expression.trimmedDescription
            let label = result.labels[0]
            return "Gen.contramap({ _mirrorExtract($0, label: \"\(raw: label)\") }, \(raw: genExpr).map \(raw: closureText))"
        } else {
            let genExprs = generatorArgs.map { $0.expression.trimmedDescription }
            let zipArgs = genExprs.joined(separator: ", ")

            let backwardLabels = buildBackwardLabels(result: result)
            let labelsArray = backwardLabels.map { "\"\($0)\"" }.joined(separator: ", ")

            return "Gen._macroZip(\(raw: zipArgs), labels: [\(raw: labelsArray)], forward: \(raw: closureText))"
        }
    }

    /// Returns labels ordered by parameter position (matching generator/tuple order).
    ///
    /// The closure parameters may appear in a different order than the initializer arguments.
    /// For example: `{ age, name in Person(name: name, age: age) }`
    /// - Parameters (generator order): [age, name]
    /// - Arguments: [name: name, age: age]
    ///
    /// The backward labels must match parameter order: ["age", "name"]
    private static func buildBackwardLabels(result: BidirectionalResult) -> [String] {
        var paramToLabel: [String: String] = [:]
        for (argIndex, paramRef) in result.argumentParamRefs.enumerated() {
            paramToLabel[paramRef] = result.labels[argIndex]
        }

        return result.parameterNames.map { paramName in
            paramToLabel[paramName]!
        }
    }

    /// Builds the expansion for the no-closure overload: pass through or zip.
    private static func buildZipExpansion(
        generatorArgs: [LabeledExprListSyntax.Element]
    ) -> ExprSyntax {
        if generatorArgs.count == 1 {
            let genExpr = generatorArgs[0].expression.trimmedDescription
            return "\(raw: genExpr)"
        } else {
            let genExprs = generatorArgs.map { $0.expression.trimmedDescription }
            let zipArgs = genExprs.joined(separator: ", ")
            return "Gen.zip(\(raw: zipArgs))"
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
