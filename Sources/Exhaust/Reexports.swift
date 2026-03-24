import ExhaustCore

// MARK: - Consumer-visible type re-exports

// These typealiases make ExhaustCore types available to consumers of the Exhaust module.
// ExhaustCore is not a product, so consumers cannot import it directly.

// MARK: - Public typealiases

public typealias ReflectiveGenerator<Output> = ExhaustCore.FreerMonad<ExhaustCore.ReflectiveOperation, Output>
public typealias SizeScaling<Bound: Sendable> = ExhaustCore.SizeScaling<Bound>
public typealias FilterType = ExhaustCore.FilterType
public typealias BitPatternConvertible = ExhaustCore.BitPatternConvertible
public typealias PartialPath = ExhaustCore.PartialPath
public typealias ExhaustLog = ExhaustCore.ExhaustLog
public typealias Interpreters = ExhaustCore.Interpreters
public typealias ReducerBudget = Interpreters.ReductionBudget
public typealias GeneratorError = ExhaustCore.GeneratorError
public typealias EncoderName = ExhaustCore.EncoderName
public typealias ReductionStats = ExhaustCore.ReductionStats

// MARK: - Internal typealiases

typealias ChoiceTreeAnalysis = ExhaustCore.ChoiceTreeAnalysis
typealias CoveringArray = ExhaustCore.CoveringArray
typealias CoveringArrayReplay = ExhaustCore.CoveringArrayReplay
typealias ChoiceSequence = ExhaustCore.ChoiceSequence
