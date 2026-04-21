// Closure analysis for #gen macro — detects struct/class initializer calls and extracts argument labels for automatic backward mapping synthesis.
//
// Adapted from Swift Testing's ConditionArgumentParsing.swift approach for analyzing closure bodies at the syntax level.
//
// Licensed under Apache License v2.0 with Runtime Library Exception.
// See https://swift.org/LICENSE.txt for license information.

import SwiftSyntax

/// The result of analyzing a closure body for bidirectional mapping capability.
enum ClosureAnalysisOutcome {
    /// The closure body is a simple initializer/function call with labeled arguments that correspond 1:1 with closure parameters, enabling backward mapping.
    case bidirectional(BidirectionalResult)

    /// The closure body is a single-argument, unlabeled type conversion (for example `Int($0)`).
    /// The backward pass is generated via constrained overloads at the expansion site rather than Mirror extraction.
    case scalarConversion

    /// The closure body cannot be automatically reversed. The associated diagnostic explains why.
    case forwardOnly(ExhaustMacroDiagnostic)
}

/// Information extracted from a successfully analyzed bidirectional closure.
struct BidirectionalResult {
    /// The argument labels from the function/initializer call, in argument order.
    /// For struct inits these become Mirror extraction labels.
    /// For enum cases with positional fallback these are ".0", ".1", and so on (unused).
    let labels: [String]

    /// The parameter names from the closure signature, in parameter order.
    /// Parameter order corresponds to generator order in Gen.zip.
    let parameterNames: [String]

    /// For each argument position, which closure parameter name was used.
    /// Same length and order as `labels`.
    let argumentParamRefs: [String]

    /// If the callee is a member access (for example `Pet.cat`), the member name.
    /// When set, the backward mapping uses pattern matching instead of Mirror.
    let caseName: String?

    /// Original argument labels from the call site, in argument order. `nil` for unlabeled arguments. Used to generate labeled pattern bindings for enum case backward mapping (for example `case let .cat(age: v0)`).
    let originalArgumentLabels: [String?]
}

/// Analyzes a closure expression to determine if it can support automatic backward mapping.
///
/// The analysis succeeds (returns `.bidirectional`) when:
/// 1. The closure has explicitly named parameters or uses shorthand `$0`, `$1`, and so on.
/// 2. The body is a single expression (or single return statement)
/// 3. That expression is a function/initializer call 4. All arguments are labeled 5. Each argument is a simple reference to a closure parameter 6. There is a 1:1 correspondence between parameters and arguments
func analyzeClosureForBidirectional(
    _ closure: ClosureExprSyntax,
    generatorCount: Int
) -> ClosureAnalysisOutcome {
    // Step 1: Extract named closure parameters
    let parameterNames: [String]
    if let signature = closure.signature {
        if let paramList = signature.parameterClause?.as(ClosureShorthandParameterListSyntax.self) {
            parameterNames = paramList.map(\.name.text)
        } else if let paramClause = signature.parameterClause?
            .as(ClosureParameterClauseSyntax.self)
        {
            parameterNames = paramClause.parameters.map(\.firstName.text)
        } else {
            return .forwardOnly(.forwardOnlyShorthandParams)
        }
    } else {
        // No signature — shorthand params ($0, $1, ...).
        // Try to analyze the body for a labeled init call with shorthand references.
        return analyzeShorthandClosure(closure, generatorCount: generatorCount)
    }

    // Step 2: Get the single expression from the body
    guard let singleExpr = extractSingleExpression(from: closure.statements) else {
        return .forwardOnly(.forwardOnlyMultiStatement)
    }

    return analyzeFunctionCall(
        singleExpr,
        parameterNames: parameterNames,
        generatorCount: generatorCount
    )
}

/// Analyzes a closure that uses shorthand parameters ($0, $1, ...) for bidirectional capability.
///
/// Shorthand params provide implicit positional ordering — `$0` corresponds to the first generator, `$1` to the second, and so on. The labels needed for Mirror-based backward extraction come from the function call argument labels, not from parameter names.
private func analyzeShorthandClosure(
    _ closure: ClosureExprSyntax,
    generatorCount: Int
) -> ClosureAnalysisOutcome {
    guard let singleExpr = extractSingleExpression(from: closure.statements) else {
        return .forwardOnly(.forwardOnlyMultiStatement)
    }

    guard let funcCall = singleExpr.as(FunctionCallExprSyntax.self) else {
        return .forwardOnly(.forwardOnlyNotFunctionCall)
    }

    let caseName = extractCaseName(from: funcCall.calledExpression)

    var labels: [String] = []
    var originalArgumentLabels: [String?] = []
    var argumentParamRefs: [String] = []
    var indices: [Int] = []

    for (index, argument) in funcCall.arguments.enumerated() {
        let originalLabel = argument.label?.text
        originalArgumentLabels.append(originalLabel)
        labels.append(originalLabel ?? ".\(index)")

        guard let declRef = argument.expression.as(DeclReferenceExprSyntax.self) else {
            return .forwardOnly(.forwardOnlyComplexArguments)
        }

        let name = declRef.baseName.text
        guard name.hasPrefix("$"), let index = Int(name.dropFirst()) else {
            return .forwardOnly(.forwardOnlyComplexArguments)
        }

        argumentParamRefs.append(name)
        indices.append(index)
    }

    // Verify the indices form exactly {0, 1, ..., generatorCount-1}
    let indexSet = Set(indices)
    let expectedSet = Set(0 ..< generatorCount)

    guard indexSet == expectedSet, indices.count == generatorCount else {
        return .forwardOnly(.forwardOnlyShorthandParams)
    }

    // Unlabeled arguments can't be extracted via Mirror (which uses property names), unless this is an enum case (which uses pattern matching instead).
    if caseName == nil, originalArgumentLabels.contains(where: { $0 == nil }) {
        if generatorCount == 1 {
            return .scalarConversion
        }
        return .forwardOnly(.forwardOnlyUnlabeledArguments)
    }

    // Parameter names in ascending index order (matching generator order)
    let parameterNames = (0 ..< generatorCount).map { "$\($0)" }

    return .bidirectional(BidirectionalResult(
        labels: labels,
        parameterNames: parameterNames,
        argumentParamRefs: argumentParamRefs,
        caseName: caseName,
        originalArgumentLabels: originalArgumentLabels
    ))
}

/// Analyzes a single expression for a function call with 1:1 parameter correspondence.
///
/// Detects two callee patterns:
/// - **Direct call** (for example `Person(name: name)`): struct/class init → Mirror-based backward
/// - **Member access** (for example `Pet.cat(age)`): likely enum case → pattern-matching backward
private func analyzeFunctionCall(
    _ singleExpr: ExprSyntax,
    parameterNames: [String],
    generatorCount: Int
) -> ClosureAnalysisOutcome {
    guard let funcCall = singleExpr.as(FunctionCallExprSyntax.self) else {
        return .forwardOnly(.forwardOnlyNotFunctionCall)
    }

    // Detect enum case callee: `Pet.cat(...)` is a MemberAccessExprSyntax.
    // Exclude explicit `.init` calls which are struct/class initializers.
    let caseName = extractCaseName(from: funcCall.calledExpression)

    var labels: [String] = []
    var originalArgumentLabels: [String?] = []
    var argumentParamRefs: [String] = []

    for (index, argument) in funcCall.arguments.enumerated() {
        let originalLabel = argument.label?.text
        originalArgumentLabels.append(originalLabel)
        // Labeled arguments use their label (struct properties).
        // Unlabeled arguments fall back to positional Mirror labels (`.0`, `.1`, …) which Mirror uses for enum associated values.
        labels.append(originalLabel ?? ".\(index)")

        guard let declRef = argument.expression.as(DeclReferenceExprSyntax.self) else {
            return .forwardOnly(.forwardOnlyComplexArguments)
        }
        argumentParamRefs.append(declRef.baseName.text)
    }

    let paramSet = Set(parameterNames)
    let argRefSet = Set(argumentParamRefs)

    guard paramSet.count == parameterNames.count,
          argRefSet.count == argumentParamRefs.count,
          paramSet == argRefSet,
          parameterNames.count == generatorCount
    else {
        return .forwardOnly(.forwardOnlyParamMismatch)
    }

    // Unlabeled arguments can't be extracted via Mirror (which uses property names), unless this is an enum case (which uses pattern matching instead).
    if caseName == nil, originalArgumentLabels.contains(where: { $0 == nil }) {
        if generatorCount == 1 {
            return .scalarConversion
        }
        return .forwardOnly(.forwardOnlyUnlabeledArguments)
    }

    return .bidirectional(BidirectionalResult(
        labels: labels,
        parameterNames: parameterNames,
        argumentParamRefs: argumentParamRefs,
        caseName: caseName,
        originalArgumentLabels: originalArgumentLabels
    ))
}

/// Extracts the enum case name from a member access callee expression.
///
/// Returns the member name for patterns like `Pet.cat(...)` or `Shape.circle(...)`, which are syntactically `MemberAccessExprSyntax` nodes. Returns `nil` for direct calls like `Person(...)` or explicit `.init(...)` calls.
private func extractCaseName(from callee: ExprSyntax) -> String? {
    guard let memberAccess = callee.as(MemberAccessExprSyntax.self) else {
        return nil
    }
    let member = memberAccess.declName.baseName.text
    // Exclude explicit .init calls — those are struct/class initializers
    guard member != "init" else { return nil }
    return member
}

/// Extracts a single expression from a code block, unwrapping a `return` statement if present.
private func extractSingleExpression(from statements: CodeBlockItemListSyntax) -> ExprSyntax? {
    guard statements.count == 1,
          let singleItem = statements.first
    else {
        return nil
    }

    // Direct expression
    if let expr = singleItem.item.as(ExprSyntax.self) {
        return expr
    }

    // Return statement wrapping an expression
    if let returnStmt = singleItem.item.as(ReturnStmtSyntax.self),
       let expr = returnStmt.expression
    {
        return expr
    }

    return nil
}
