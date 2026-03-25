import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

/// Expression macro that transforms `#gen(gen1, gen2, ...) { params in Body(...) }` into a `ReflectiveGenerator` with automatic backward mapping when possible.
///
/// When the closure body is a struct or class initializer call with labeled arguments that map 1:1 to the closure parameters, the macro synthesizes a Mirror-based backward mapping, producing a fully bidirectional generator.
///
/// When the closure body is an enum case construction (detected via member access callee, e.g. `Pet.cat(age)`), the macro synthesizes a pattern-matching backward closure inspired by [swift-case-paths](https://github.com/pointfreeco/swift-case-paths) by Point-Free. This returns `nil` for non-matching cases, enabling `pick` to prune branches during reflection.
///
/// When backward inference is not possible (complex expressions, multi-statement bodies), the macro falls back to a forward-only `.map` with a warning.
public struct GenerateMacro: ExpressionMacro {
    public static func expansion(
        of node: some FreestandingMacroExpansionSyntax,
        in context: some MacroExpansionContext
    ) throws -> ExprSyntax {
        let generatorArgs = node.arguments.map(\.self)
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
        let outcome = analyzeClosureForBidirectional(
            trailingClosure,
            generatorCount: generatorCount
        )

        switch outcome {
        case let .bidirectional(result):
            return buildBidirectionalExpansion(
                generatorArgs: generatorArgs,
                closure: trailingClosure,
                result: result
            )
        case .scalarConversion:
            return buildScalarConversionExpansion(
                generatorArg: generatorArgs[0],
                closure: trailingClosure
            )
        case .forwardOnly:
            return buildForwardOnlyExpansion(
                generatorArgs: generatorArgs,
                closure: trailingClosure
            )
        }
    }

    /// Builds the expansion for a bidirectional mapping.
    ///
    /// Dispatches to either Mirror-based extraction (struct/class init) or pattern-matching extraction (enum case) based on whether the closure analysis detected a member access callee.
    private static func buildBidirectionalExpansion(
        generatorArgs: [LabeledExprListSyntax.Element],
        closure: ClosureExprSyntax,
        result: BidirectionalResult
    ) -> ExprSyntax {
        if result.caseName != nil {
            buildEnumCaseExpansion(
                generatorArgs: generatorArgs,
                closure: closure,
                result: result
            )
        } else {
            buildMirrorExpansion(
                generatorArgs: generatorArgs,
                closure: closure,
                result: result
            )
        }
    }

    // MARK: - Mirror-based expansion (struct/class init)

    /// Builds the expansion using Mirror-based backward extraction for struct/class inits.
    private static func buildMirrorExpansion(
        generatorArgs: [LabeledExprListSyntax.Element],
        closure: ClosureExprSyntax,
        result: BidirectionalResult
    ) -> ExprSyntax {
        let closureText = closure.trimmedDescription

        if generatorArgs.count == 1 {
            let genExpr = generatorArgs[0].expression.trimmedDescription
            let label = result.labels[0]
            return "__ExhaustRuntime._macroMap(\(raw: genExpr), label: \"\(raw: label)\", forward: \(raw: closureText))"
        } else {
            let genExprs = generatorArgs.map(\.expression.trimmedDescription)
            let zipArgs = genExprs.joined(separator: ", ")

            let backwardLabels = buildBackwardLabels(result: result)
            let labelsArray = backwardLabels.map { "\"\($0)\"" }.joined(separator: ", ")

            return "__ExhaustRuntime._macroZip(\(raw: zipArgs), labels: [\(raw: labelsArray)], forward: \(raw: closureText))"
        }
    }

    /// Returns Mirror labels ordered by parameter position (matching generator/tuple order).
    private static func buildBackwardLabels(result: BidirectionalResult) -> [String] {
        var paramToLabel: [String: String] = [:]
        for (argIndex, paramRef) in result.argumentParamRefs.enumerated() {
            paramToLabel[paramRef] = result.labels[argIndex]
        }

        return result.parameterNames.map { paramName in
            paramToLabel[paramName]!
        }
    }

    // MARK: - Pattern-matching expansion (enum cases)

    /// Builds the expansion using pattern-matching backward extraction for enum cases.
    ///
    /// Generates `guard case let .caseName(bindings) = $0 else { return nil }` closures for the backward pass. This approach is inspired by [swift-case-paths](https://github.com/pointfreeco/swift-case-paths) by Point-Free.
    private static func buildEnumCaseExpansion(
        generatorArgs: [LabeledExprListSyntax.Element],
        closure: ClosureExprSyntax,
        result: BidirectionalResult
    ) -> ExprSyntax {
        let closureText = closure.trimmedDescription
        let caseName = result.caseName!
        let argCount = result.originalArgumentLabels.count

        // Build pattern bindings: `v0`, `v1`, ... with optional labels: `age: v0`
        let patternBindings = (0 ..< argCount).map { i -> String in
            if let label = result.originalArgumentLabels[i] {
                return "\(label): v\(i)"
            }
            return "v\(i)"
        }.joined(separator: ", ")

        let casePattern = ".\(caseName)(\(patternBindings))"

        if generatorArgs.count == 1 {
            let genExpr = generatorArgs[0].expression.trimmedDescription
            let backward = "{ guard case let \(casePattern) = $0 else { return nil }; return v0 }"
            return "__ExhaustRuntime._macroMap(\(raw: genExpr), backward: \(raw: backward), forward: \(raw: closureText))"
        } else {
            let genExprs = generatorArgs.map(\.expression.trimmedDescription)
            let zipArgs = genExprs.joined(separator: ", ")

            // Reorder bindings from argument order to generator/parameter order
            let paramOrder = buildBackwardArgIndices(result: result)
            let returnValues = paramOrder.map { "v\($0) as Any" }.joined(separator: ", ")

            let backward = "{ guard case let \(casePattern) = $0 else { return nil }; return [\(returnValues)] }"
            return "__ExhaustRuntime._macroZip(\(raw: zipArgs), backward: \(raw: backward), forward: \(raw: closureText))"
        }
    }

    /// Returns argument indices ordered by parameter position (matching generator order).
    ///
    /// Pattern match bindings are in argument order (matching enum declaration order).
    /// Generators are in parameter order. This maps parameter → argument index so the backward closure returns values in the order the zip expects.
    private static func buildBackwardArgIndices(result: BidirectionalResult) -> [Int] {
        var paramToArgIndex: [String: Int] = [:]
        for (argIndex, paramRef) in result.argumentParamRefs.enumerated() {
            paramToArgIndex[paramRef] = argIndex
        }
        return result.parameterNames.map { paramToArgIndex[$0]! }
    }

    /// Builds the expansion for a single-generator, unlabeled-argument closure (e.g. `#gen(.uint64()) { Int($0) }`).
    ///
    /// Emits `__ExhaustRuntime._macroMapScalar(gen, forward: closure)` which has constrained overloads for `BinaryInteger` and `BinaryFloatingPoint` that synthesize the backward pass at compile time, with an unconstrained fallback that is forward-only.
    private static func buildScalarConversionExpansion(
        generatorArg: LabeledExprListSyntax.Element,
        closure: ClosureExprSyntax
    ) -> ExprSyntax {
        let genExpr = generatorArg.expression.trimmedDescription
        let closureText = closure.trimmedDescription
        return "__ExhaustRuntime._macroMapScalar(\(raw: genExpr), forward: \(raw: closureText))"
    }

    /// Builds the expansion for the no-closure overload: pass through or zip.
    private static func buildZipExpansion(
        generatorArgs: [LabeledExprListSyntax.Element]
    ) -> ExprSyntax {
        if generatorArgs.count == 1 {
            let genExpr = generatorArgs[0].expression.trimmedDescription
            return "\(raw: genExpr)"
        } else {
            let genExprs = generatorArgs.map(\.expression.trimmedDescription)
            let zipArgs = genExprs.joined(separator: ", ")
            return "__ExhaustRuntime.__zip(\(raw: zipArgs))"
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
            let genExprs = generatorArgs.map(\.expression.trimmedDescription)
            let zipArgs = genExprs.joined(separator: ", ")
            return "__ExhaustRuntime.__zip(\(raw: zipArgs)).map \(raw: closureText)"
        }
    }
}
