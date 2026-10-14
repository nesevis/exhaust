//
//  ScopedEncoder.swift
//  Exhaust
//

// MARK: - Encoder Protocol

/// A stateless search definition: what the runner needs to gate an encoder, retain or discard its sources, and build the encoder's reducer for one dispatched scope.
///
/// Everything the runner asks of an encoder before dispatch is static, so it is read from the encoder's type through ``AnyEncoderScope/encoder`` without building one. The runner constructs an encoder only to build its reducer, with the run's ``ScopedReductionTuning``, which is the only place budgets are set.
///
/// Discovery and ranking belong to the family sources in ``ScopedSource``, not the encoder: one family query finds scopes for several encoders, and a single priority order across them decides which runs first.
protocol ScopedEncoder {
    /// The dispatched unit of work, with any runner-resolved budgets already applied.
    associatedtype Scope

    /// The name the configuration's enabled encoders, statistics, and reports use for this encoder.
    static var name: EncoderName { get }

    /// Whether the encoder's scopes depend on leaf values rather than only on graph topology. A source holding such scopes is prepared again after any value change.
    static var isValueDependent: Bool { get }

    /// Whether the encoder lifts its probes through a materialization, and so needs the generator in hand. Relax round exploitation has none to give and skips these.
    static var requiresGenerator: Bool { get }

    /// Whether the encoder changes the generator's active execution path. Only replacement does, so on a graph stripped of unselected branches it needs them restored first.
    static var isPathChanging: Bool { get }

    /// Binds the search to `scope` over the snapshot in `input`. Called only for a scope the runner has selected.
    func reducer(_ scope: Scope, input: ScopedEncoderInput) -> ScopedReducer
}

// MARK: - Encoder Input

/// The snapshot the encoder's reducer for a scope is built against: the incumbent's sequence, tree, and graph when the scope is dispatched.
struct ScopedEncoderInput {
    let baseSequence: ChoiceSequence
    let tree: ChoiceTree
    let graph: ChoiceGraph
    /// Convergence records keyed by graph node ID, so a value search starts each leaf from its last known floor.
    let warmStartRecords: [Int: ConvergedOrigin]
}
