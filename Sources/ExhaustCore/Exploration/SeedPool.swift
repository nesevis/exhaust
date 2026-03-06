//
//  SeedPool.swift
//  Exhaust
//

// MARK: - Seed

/// A seed: the ChoiceSequence (for mutation) + ChoiceTree (for structural info) + metadata.
public struct Seed {
    public let sequence: ChoiceSequence
    public let tree: ChoiceTree
    public var noveltyScore: Double
    /// Target function score. Used for fitness-guided search when a `.target` is provided.
    public var fitness: Double
    /// Which explore iteration discovered this seed.
    public let generation: UInt64

    public init(
        sequence: ChoiceSequence,
        tree: ChoiceTree,
        noveltyScore: Double,
        fitness: Double = 0,
        generation: UInt64,
    ) {
        self.sequence = sequence
        self.tree = tree
        self.noveltyScore = noveltyScore
        self.fitness = fitness
        self.generation = generation
    }
}

// MARK: - SearchDirective

public enum SearchDirective {
    /// Produce a fresh value from the generator.
    case generate
    /// Mutate an existing interesting seed.
    case mutate(Seed)
}

// MARK: - SeedPool

/// Storage + sampling of interesting inputs.
public protocol SeedPool {
    /// Add a seed deemed interesting. Pool decides whether to accept and where to rank it.
    mutating func invest(_ seed: Seed)

    /// Signal that the most-recently-sampled seed produced nothing useful.
    mutating func revise()

    /// Sample the next seed to mutate, or `.generate` for a fresh random input.
    mutating func sample(using prng: inout Xoshiro256) -> SearchDirective

    /// The pool's current size.
    var count: Int { get }
}
