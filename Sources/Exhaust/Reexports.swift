import ExhaustCore

// MARK: - Consumer-visible type re-exports

// These typealiases make ExhaustCore types available to consumers of the Exhaust module.
// ExhaustCore is not a product, so consumers cannot import it directly.

// MARK: - Public typealiases

/// A bidirectional generator that produces values and reflects on them to enable test-case reduction.
public typealias ReflectiveGenerator<Output> = ExhaustCore.FreerMonad<ExhaustCore.ReflectiveOperation, Output>
/// Controls how generated counts scale with the size parameter.
public typealias SizeScaling<Bound: Sendable> = ExhaustCore.SizeScaling<Bound>
/// Specifies how the rejection-sampling filter behaves when values are discarded.
public typealias FilterType = ExhaustCore.FilterType
/// A type that can be converted to and from a `UInt64` bit pattern for use in generators.
public typealias BitPatternConvertible = ExhaustCore.BitPatternConvertible
/// A key-path-like abstraction for partial extraction, used in bidirectional generator mappings.
public typealias PartialPath = ExhaustCore.PartialPath
/// Namespace for interpreter entry points (generation, reflection, replay).
public typealias Interpreters = ExhaustCore.Interpreters
/// Errors thrown during generator construction or runtime validation.
public typealias GeneratorError = ExhaustCore.GeneratorError
/// Identifies a specific encoder in the choice-graph reducer.
public typealias EncoderName = ExhaustCore.EncoderName
/// Statistics accumulated during a single reduction run.
public typealias ReductionStats = ExhaustCore.ReductionStats
/// Statistics accumulated during a choice-graph reduction pass.
public typealias ChoiceGraphStats = ExhaustCore.ChoiceGraphStats
/// The minimum log level for ``ExhaustLog`` output.
public typealias LogLevel = ExhaustCore.LogLevel
/// The output format for ``ExhaustLog`` messages.
public typealias LogFormat = ExhaustCore.LogFormat

// MARK: - Package typealiases

package typealias ExhaustLog = ExhaustCore.ExhaustLog

// MARK: - Internal typealiases

typealias ChoiceTreeAnalysis = ExhaustCore.ChoiceTreeAnalysis
typealias CoveringArrayReplay = ExhaustCore.CoveringArrayReplay
typealias ChoiceSequence = ExhaustCore.ChoiceSequence
