import SwiftDiagnostics

enum ExhaustMacroDiagnostic: String, DiagnosticMessage {
    case forwardOnlyShorthandParams = "Cannot infer backward mapping: shorthand parameter indices must be exactly $0 ..< N with no duplicates or gaps"
    case forwardOnlyMultiStatement = "Cannot infer backward mapping: multi-statement closures cannot be analyzed"
    case forwardOnlyNotFunctionCall = "Cannot infer backward mapping: closure body is not an initializer or function call"
    case forwardOnlyUnlabeledArguments = "Cannot infer backward mapping: unlabeled arguments cannot map to property names"
    case forwardOnlyComplexArguments = "Cannot infer backward mapping: arguments must be simple parameter references"
    case forwardOnlyParamMismatch = "Cannot infer backward mapping: closure parameters do not correspond 1:1 with call arguments"
    case noGeneratorArguments = "#gen requires at least one generator argument"
    case exhaustMissingProperty = "#exhaust requires a property (trailing closure or 'property:' argument)"
    case exhaustMissingGenerator = "#exhaust requires a generator as its first argument"
    case exploreMissingProperty = "#explore requires a property (trailing closure or 'property:' argument)"
    case exploreMissingGenerator = "#explore requires a generator as its first argument"
    case exploreMissingDirections = "#explore requires a 'directions:' argument"
    case exampleMissingGenerator = "#example requires a generator as its first argument"
    case examineMissingGenerator = "#examine requires a generator as its first argument"
    case exhaustContractMissingSpec = "#execute requires a spec type argument"
    case closureCannotFail = "Closure has no failure mechanism (throw, try, #expect, #require, or Issue.record); test will always pass"
    case closureCannotFailXCTest = "Closure has no failure mechanism; return a Bool or throw an error to signal failure"
    case xcTestUnwrapInPropertyClosure = "XCTUnwrap is expensive on failure (several hundred milliseconds per call); prefer a guard or throwing an explicit error"
    case xcTestAssertInPropertyClosure = "XCTAssert failures are invisible to Exhaust and will not trigger reduction; return a Bool or throw an error instead"

    var message: String {
        rawValue
    }

    var diagnosticID: MessageID {
        MessageID(domain: "ExhaustMacros", id: "\(self)")
    }

    var severity: DiagnosticSeverity {
        switch self {
            case .forwardOnlyShorthandParams,
                 .forwardOnlyMultiStatement,
                 .forwardOnlyNotFunctionCall,
                 .forwardOnlyUnlabeledArguments,
                 .forwardOnlyComplexArguments,
                 .forwardOnlyParamMismatch,
                 .xcTestUnwrapInPropertyClosure,
                 .xcTestAssertInPropertyClosure:
                .warning
            case .noGeneratorArguments,
                 .exhaustMissingProperty,
                 .exhaustMissingGenerator,
                 .exploreMissingProperty,
                 .exploreMissingGenerator,
                 .exploreMissingDirections,
                 .exampleMissingGenerator,
                 .examineMissingGenerator,
                 .exhaustContractMissingSpec,
                 .closureCannotFail,
                 .closureCannotFailXCTest:
                .error
        }
    }
}
