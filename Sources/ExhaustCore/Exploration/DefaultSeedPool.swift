//
//  DefaultSeedPool.swift
//  Exhaust
//

/// A bounded seed pool with dual-mode ranking: fitness-weighted when a target function is provided, novelty-weighted otherwise.
///
/// **Fitness mode** (when `useFitness` is `true`):
/// - **Insertion**: Accept if novelty > 0 OR fitness exceeds the pool minimum.
///   Evict the lowest-fitness seed at capacity.
/// - **Sampling**: Weighted random by fitness score.
/// - **Revise**: Halves the fitness score of the most-recently-sampled seed.
///
/// **Novelty mode** (default):
/// - **Insertion**: Accept if novelty > 0. Evict the lowest-novelty seed.
/// - **Sampling**: Weighted random by novelty score.
/// - **Revise**: Halves the novelty score of the most-recently-sampled seed.
public struct DefaultSeedPool: SeedPool {
    private var seeds: [Seed] = []
    private let capacity: Int
    private let generateRatio: Double
    private let useFitness: Bool
    private var lastSampledIndex: Int?

    public init(
        capacity: Int = 256,
        generateRatio: Double = 0.2,
        useFitness: Bool = false
    ) {
        self.capacity = capacity
        self.generateRatio = generateRatio
        self.useFitness = useFitness
    }

    public var count: Int {
        seeds.count
    }

    /// Returns `true` when the pool contains no seeds.
    public var isEmpty: Bool {
        seeds.isEmpty
    }

    /// The average fitness across all seeds in the pool.
    public var averageFitness: Double {
        guard !seeds.isEmpty else { return 0 }
        return seeds.reduce(0.0) { $0 + $1.fitness } / Double(seeds.count)
    }

    public mutating func invest(_ seed: Seed) {
        if useFitness {
            investFitness(seed)
        } else {
            investNovelty(seed)
        }
    }

    public mutating func revise() {
        guard let i = lastSampledIndex, i < seeds.count else { return }
        if useFitness {
            seeds[i].fitness *= 0.5
        } else {
            seeds[i].noveltyScore *= 0.5
        }
    }

    public mutating func sample(using prng: inout Xoshiro256) -> SearchDirective {
        guard !seeds.isEmpty else { return .generate }

        // With generateRatio probability, produce a fresh value
        let roll = Double(prng.next(upperBound: 1000)) / 1000.0
        if roll < generateRatio {
            lastSampledIndex = nil
            return .generate
        }

        let weight: (Seed) -> Double = useFitness
            ? { max($0.fitness, 0.01) }
            : { max($0.noveltyScore, 0.01) }

        // Weighted random sampling
        let totalWeight = seeds.reduce(0.0) { $0 + weight($1) }
        var target = Double(prng.next(upperBound: UInt64(totalWeight * 1000.0))) / 1000.0

        for (i, seed) in seeds.enumerated() {
            target -= weight(seed)
            if target <= 0 {
                lastSampledIndex = i
                return .mutate(seed)
            }
        }

        // Fallback: return last seed
        let i = seeds.count - 1
        lastSampledIndex = i
        return .mutate(seeds[i])
    }

    // MARK: - Private

    private mutating func investNovelty(_ seed: Seed) {
        guard seed.noveltyScore > 0 else { return }

        if seeds.count >= capacity {
            guard let minIdx = seeds.indices.min(by: { seeds[$0].noveltyScore < seeds[$1].noveltyScore }) else {
                return
            }
            if seed.noveltyScore > seeds[minIdx].noveltyScore {
                seeds[minIdx] = seed
                if lastSampledIndex == minIdx {
                    lastSampledIndex = nil
                }
            }
        } else {
            seeds.append(seed)
        }
    }

    private mutating func investFitness(_ seed: Seed) {
        // Accept if novelty > 0 (structurally new) OR fitness exceeds pool minimum
        let poolMinFitness = seeds.min(by: { $0.fitness < $1.fitness })?.fitness ?? 0
        guard seed.noveltyScore > 0 || seed.fitness > poolMinFitness else { return }

        if seeds.count >= capacity {
            // Evict lowest-fitness seed
            guard let minIdx = seeds.indices.min(by: { seeds[$0].fitness < seeds[$1].fitness }) else {
                return
            }
            if seed.fitness > seeds[minIdx].fitness || seed.noveltyScore > 0 {
                seeds[minIdx] = seed
                if lastSampledIndex == minIdx {
                    lastSampledIndex = nil
                }
            }
        } else {
            seeds.append(seed)
        }
    }
}
