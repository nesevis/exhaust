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
    case exploreMissingScorer = "#explore requires a 'scorer:' argument"
    case extractMissingGenerator = "#extract requires a generator as its first argument"
    case examineMissingGenerator = "#examine requires a generator as its first argument"

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
             .forwardOnlyParamMismatch:
            .warning
        case .noGeneratorArguments,
             .exhaustMissingProperty,
             .exhaustMissingGenerator,
             .exploreMissingProperty,
             .exploreMissingGenerator,
             .exploreMissingScorer,
             .extractMissingGenerator,
             .examineMissingGenerator:
            .error
        }
    }
}
