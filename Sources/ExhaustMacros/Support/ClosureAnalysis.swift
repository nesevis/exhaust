// Closure analysis for #generate macro — detects struct/class initializer calls
// and extracts argument labels for automatic backward mapping synthesis.
//
// Adapted from Swift Testing's ConditionArgumentParsing.swift approach for
// analyzing closure bodies at the syntax level.
//
// Licensed under Apache License v2.0 with Runtime Library Exception.
// See https://swift.org/LICENSE.txt for license information.

import SwiftSyntax

/// The result of analyzing a closure body for bidirectional mapping capability.
enum ClosureAnalysisOutcome {
    /// The closure body is a simple initializer/function call with labeled arguments
    /// that correspond 1:1 with closure parameters, enabling backward mapping.
    case bidirectional(BidirectionalResult)

    /// The closure body cannot be automatically reversed. The associated diagnostic
    /// explains why.
    case forwardOnly(ExhaustMacroDiagnostic)
}

/// Information extracted from a successfully analyzed bidirectional closure.
struct BidirectionalResult {
    /// The argument labels from the function/initializer call, in argument order.
    /// These become property access paths in the backward mapping.
    let labels: [String]

    /// The parameter names from the closure signature, in parameter order.
    /// Parameter order corresponds to generator order in Gen.zip.
    let parameterNames: [String]

    /// For each argument position, which closure parameter name was used.
    /// Same length and order as `labels`.
    let argumentParamRefs: [String]
}

/// Analyzes a closure expression to determine if it can support automatic backward mapping.
///
/// The analysis succeeds (returns `.bidirectional`) when:
/// 1. The closure has explicitly named parameters (not $0, $1)
/// 2. The body is a single expression (or single return statement)
/// 3. That expression is a function/initializer call
/// 4. All arguments are labeled
/// 5. Each argument is a simple reference to a closure parameter
/// 6. There is a 1:1 correspondence between parameters and arguments
func analyzeClosureForBidirectional(
    _ closure: ClosureExprSyntax,
    generatorCount: Int
) -> ClosureAnalysisOutcome {
    // Step 1: Extract named closure parameters
    let parameterNames: [String]
    if let signature = closure.signature {
        if let paramList = signature.parameterClause?.as(ClosureShorthandParameterListSyntax.self) {
            parameterNames = paramList.map { $0.name.text }
        } else if let paramClause = signature.parameterClause?.as(ClosureParameterClauseSyntax.self) {
            parameterNames = paramClause.parameters.map { $0.firstName.text }
        } else {
            return .forwardOnly(.forwardOnlyShorthandParams)
        }
    } else {
        // No signature at all — implies shorthand params
        return .forwardOnly(.forwardOnlyShorthandParams)
    }

    // Step 2: Get the single expression from the body
    guard let singleExpr = extractSingleExpression(from: closure.statements) else {
        return .forwardOnly(.forwardOnlyMultiStatement)
    }

    // Step 3: Check it's a function call
    guard let funcCall = singleExpr.as(FunctionCallExprSyntax.self) else {
        return .forwardOnly(.forwardOnlyNotFunctionCall)
    }

    // Step 4: Extract argument labels — all must be labeled
    var labels: [String] = []
    var argumentParamRefs: [String] = []

    for argument in funcCall.arguments {
        guard let label = argument.label?.text else {
            return .forwardOnly(.forwardOnlyUnlabeledArguments)
        }
        labels.append(label)

        // Step 5: Each argument must be a simple DeclReferenceExpr matching a closure param
        guard let declRef = argument.expression.as(DeclReferenceExprSyntax.self) else {
            return .forwardOnly(.forwardOnlyComplexArguments)
        }
        argumentParamRefs.append(declRef.baseName.text)
    }

    // Step 6: Verify 1:1 correspondence
    let paramSet = Set(parameterNames)
    let argRefSet = Set(argumentParamRefs)

    guard paramSet.count == parameterNames.count,
          argRefSet.count == argumentParamRefs.count,
          paramSet == argRefSet,
          parameterNames.count == generatorCount
    else {
        return .forwardOnly(.forwardOnlyParamMismatch)
    }

    return .bidirectional(BidirectionalResult(
        labels: labels,
        parameterNames: parameterNames,
        argumentParamRefs: argumentParamRefs
    ))
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
       let expr = returnStmt.expression {
        return expr
    }

    return nil
}
