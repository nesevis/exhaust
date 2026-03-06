import ExhaustCore

// MARK: - Consumer-visible type re-exports

// These typealiases make ExhaustCore types available to consumers of the Exhaust module.
// ExhaustCore is not a product, so consumers cannot import it directly.

public typealias ReflectiveGenerator<Output> = ExhaustCore.FreerMonad<ExhaustCore.ReflectiveOperation, Output>
public typealias SizeScaling<Bound: Sendable> = ExhaustCore.SizeScaling<Bound>
public typealias FilterType = ExhaustCore.FilterType
public typealias BitPatternConvertible = ExhaustCore.BitPatternConvertible
public typealias PartialPath = ExhaustCore.PartialPath
public typealias ExhaustLog = ExhaustCore.ExhaustLog
public typealias Interpreters = ExhaustCore.Interpreters
public typealias ShrinkBudget = Interpreters.ShrinkConfiguration
public typealias GeneratorError = ExhaustCore.GeneratorError
