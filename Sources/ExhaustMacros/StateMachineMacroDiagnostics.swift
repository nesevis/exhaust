import SwiftDiagnostics
import SwiftSyntax

enum StateMachineDiagnostic: String, DiagnosticMessage {
    case noCommands = "@StateMachine requires at least one @Command method"
    case noSUT = "@StateMachine requires exactly one @SystemUnderTest property"
    case multipleSUT = "@StateMachine requires exactly one @SystemUnderTest property, but multiple were found"
    case sutTypeNotInferred = "@SystemUnderTest property type could not be inferred — add an explicit type annotation"
    case commandMissingGenerators = "@Command method has parameters but no generator expressions — add generators to the @Command attribute"
    case structNotAllowed = "State machine specs must be a 'final class' or 'actor' — structs are not supported"
    case missingMode = "@StateMachine requires an execution mode: @StateMachine(.sequential|.tasks|.threads)"
    case nonLiteralMode = "The execution mode must be a literal ExecutionModel case (.sequential|.tasks|.threads)"
    case oracleRequiresThreads = "@Oracle is only used with @StateMachine(.threads). For @StateMachine(.sequential) or @StateMachine(.tasks), use @Invariant instead"
    case invariantUnderThreads = "@Invariant requires deterministic per-step state, which a preemptive run does not have. Use @StateMachine(.tasks)"
    case noOracle = "@StateMachine(.threads) requires exactly one @Oracle method"
    case multipleOracles = "@StateMachine(.threads) allows only one @Oracle method"
    case actorRequiresSequential = "Actor specs must use @StateMachine(.sequential). Actor isolation serializes all dispatch, so concurrent testing has nowhere to interleave"
    case actorWithThreads = "Actor specs must use @StateMachine(.sequential). Actors are data-race-free, so .threads cannot surface races in them"
    case duplicateCommandName = "Two @Command methods share the same base name — rename one or merge them"
    case invalidCommandWeight = "@Command weight must be a positive integer literal"
    case oracleParameterCount = "@Oracle must take exactly one parameter of the SystemUnderTest type"
    case commandHasUnsupportedParameter = "@Command parameters must not be inout, variadic, or generic — the synthesized Command enum cannot represent them"
    case multipleSetups = "@StateMachine allows only one @Setup method — merge multi-phase setup into one method whose body runs the phases in order"
    case setupConflictingMarker = "@Setup cannot be combined with @Command, @Invariant, or @Oracle on the same method"
    case setupMissingGenerators = "@Setup method has parameters but no generator expressions — add generators to the @Setup attribute"
    case setupHasUnsupportedParameter = "@Setup parameters must not be inout, variadic, or generic — the synthesized SetupStep enum cannot represent them"
    case mainActorSetup = "Setup methods isolated to @MainActor are unsupported because synthesized setup dispatch is nonisolated"
    case invariantHasParameters = "@Invariant methods must not take parameters because Exhaust calls them after every command"
    case throwingOracle = "@Oracle methods must not throw because oracle checks cannot propagate errors"
    case mainActorCommand = "Commands isolated to @MainActor are unsupported because synthesized command dispatch is nonisolated"

    var message: String {
        rawValue
    }

    var diagnosticID: MessageID {
        MessageID(domain: "ExhaustMacros", id: "\(self)")
    }

    var severity: DiagnosticSeverity {
        switch self {
            case .noCommands, .noSUT, .multipleSUT, .sutTypeNotInferred, .commandMissingGenerators,
                 .structNotAllowed, .missingMode, .nonLiteralMode, .noOracle, .multipleOracles,
                 .actorRequiresSequential, .actorWithThreads,
                 .duplicateCommandName, .invalidCommandWeight, .oracleParameterCount,
                 .commandHasUnsupportedParameter, .invariantHasParameters, .throwingOracle,
                 .mainActorCommand,
                 .multipleSetups, .setupConflictingMarker, .setupMissingGenerators,
                 .setupHasUnsupportedParameter, .mainActorSetup:
                .error
            case .oracleRequiresThreads, .invariantUnderThreads:
                .warning
        }
    }
}

/// Diagnostic for a marker method declared `static` or `class`.
///
/// Carries the marker name so the message names the attribute the user actually wrote, and each marker keeps its own diagnostic ID so downstream tooling can tell them apart.
struct TypeMemberMarkerDiagnostic: DiagnosticMessage {
    let marker: String

    var message: String {
        "@\(marker) must be applied to an instance method — the synthesized dispatch calls it on the spec instance, which Swift rejects for static and class members"
    }

    var diagnosticID: MessageID {
        MessageID(domain: "ExhaustMacros", id: "static\(marker)Method")
    }

    var severity: DiagnosticSeverity {
        .error
    }
}

/// Diagnostic for a `@Command` or `@Setup` method whose generator count does not match its parameter count.
///
/// Carries both counts so the message names the exact mismatch rather than a generic "wrong generators" note. The marker keeps the message and the diagnostic ID specific to the attribute the user actually wrote.
struct GeneratorArityDiagnostic: DiagnosticMessage {
    /// The attribute the mismatch was found on. Each marker keeps its own diagnostic ID so downstream tooling can tell the two apart.
    enum Marker: String {
        case command = "Command"
        case setup = "Setup"

        var diagnosticIdentifier: String {
            switch self {
                case .command:
                    "commandGeneratorArityMismatch"
                case .setup:
                    "setupGeneratorArityMismatch"
            }
        }
    }

    let marker: Marker
    let parameterCount: Int
    let generatorCount: Int

    var message: String {
        "@\(marker.rawValue) has \(parameterCount) parameter\(parameterCount == 1 ? "" : "s") but \(generatorCount) generator\(generatorCount == 1 ? "" : "s") — provide exactly one generator per parameter"
    }

    var diagnosticID: MessageID {
        MessageID(domain: "ExhaustMacros", id: marker.diagnosticIdentifier)
    }

    var severity: DiagnosticSeverity {
        .error
    }
}
