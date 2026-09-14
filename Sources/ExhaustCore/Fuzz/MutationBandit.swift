// Adaptive mutation-arm selection for the mutation phase.
//
// A uniform draw over the intensity bands is the naive default the literature beats twice over: stacking several operators per child outperforms one-at-a-time (Wu et al., "One Fuzzing Strategy to Rule Them All", ICSE 2022), and the right operator weights vary by target, so any fixed tuning loses to an adaptive one (same paper; MOpt, USENIX Security 2019). The bandit here is EXP3 (exponential-weight exploration/exploitation), chosen over discounted UCB because the reward signal — corpus admission — is sparse and non-stationary in exactly the way EXP3's adversarial guarantees tolerate: admission rates collapse as coverage saturates, and a band that stops paying should decay rather than coast on stale confidence intervals.
//
// One deviation from textbook EXP3: the action set varies by round. An arm whose operator cannot fire on the current parent is withheld and the distribution is renormalized over the rest, which makes this EXP3 over sleeping experts rather than over a fixed inventory. The importance weight follows the restriction — rewards divide by the probability the draw actually ran at, not by the unconditional one — so a round that withheld most of the distribution does not inflate what the survivors learn. Each child comes from exactly one arm, so the reward lands on the arm that produced it; stacked children, which would have made this a combinatorial bandit problem, were removed after measuring neutral-to-worse.
//
// The bandit ships on because the inventory is ten arms, six of which are graph and pair operators that miss cheaply on parents they cannot target; a uniform draw over that inventory spends children on misses. The four-arm inventory it was first measured against (2026-07-11, neutral-to-worse) gave a uniform draw little to get wrong, so that result does not carry over. The comparison that would settle it, bandit against the fixed distribution over the same ten arms, has not been run.

import Foundation

/// One selectable mutation operator: the three intensity bands, the bind-boundary splice, the graph-targeted operators behind the `graphMutation` knob, and the pair operators behind the `pairMutation` knob.
package enum MutationArm: Int, CaseIterable, Sendable {
    case low = 0
    case medium = 1
    case high = 2
    case splice = 3
    case swap = 4
    case shuffle = 5
    case move = 6
    case lockstepDelta = 7
    case twinSplice = 8
    case typedCrossover = 9
    case elementDeletion = 10
    case elementDuplication = 11
    /// Redraws one or more independent leaves or pick subtrees of the parent from the PRNG at their own sites, keeping everything outside them. See ``FuzzMutator/valueReseed(_:targets:prng:)``.
    case valueReseed = 12
    /// Removes a run of consecutive elements from one sequence node. See ``FuzzMutator/deleteElementRun(_:targets:prng:)``.
    case runDeletion = 13
    /// Repeats a run of consecutive elements of one sequence node in place. See ``FuzzMutator/duplicateElementRun(_:targets:prng:)``.
    case runDuplication = 14
    /// Copies one run of a sequence node over another run of the same node. See ``FuzzMutator/copyElementRun(_:targets:prng:)``.
    case runCopy = 15
    /// Cuts a sequence node at an element and reseeds every independent site after the cut. See ``FuzzMutator/suffixReseed(_:targets:prng:)``.
    case suffixReseed = 16

    /// The inventory with the targeting knobs off: the three intensity bands and splice. Raw values order the knob-gated arms after these, so this is the raw-value prefix of the inventory.
    package static let bandArms: [MutationArm] = [.low, .medium, .high, .splice]

    /// The arm credited for a band mutation of this intensity.
    ///
    /// An explicit map rather than shared index arithmetic: the two enums declare their cases independently, and deriving one from the other's `allCases` position would silently mis-credit the bandit if either reordered, with no test failing.
    package init(intensity: MutationIntensity) {
        self = switch intensity {
            case .low:
                .low
            case .medium:
                .medium
            case .high:
                .high
        }
    }
}

/// A set of ``MutationArm`` values held in one word.
///
/// The inventory is ten arms, and the set is built once per candidate and then tested once per arm, so a bit set that stays in a register costs a shift and a mask where a `Set` would cost a hash and an allocation. It is a distinct type rather than a bare `UInt32` because nothing in the signature of a word says which bits mean what.
package struct MutationArmSet: Sendable, Equatable {
    package private(set) var rawValue: UInt32

    /// The set containing every arm, which is what a caller passes when it is not narrowing the inventory.
    package static let all = MutationArmSet(rawValue: .max)

    /// The set containing no arm, the identity a union accumulates from.
    package static let none = MutationArmSet(rawValue: 0)

    /// The three intensity bands. They rewrite the flat sequence and fall back within themselves when the shape they prefer is absent, so no structure can rule one out.
    package static let bands = MutationArmSet(.low, .medium, .high)

    package init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    package init(_ arms: MutationArm...) {
        rawValue = arms.reduce(into: 0) { result, arm in
            result |= 1 << UInt32(arm.rawValue)
        }
    }

    package func contains(_ arm: MutationArm) -> Bool {
        rawValue & (1 << UInt32(arm.rawValue)) != 0
    }

    package mutating func insert(_ arm: MutationArm) {
        rawValue |= 1 << UInt32(arm.rawValue)
    }

    package func intersection(_ other: MutationArmSet) -> MutationArmSet {
        MutationArmSet(rawValue: rawValue & other.rawValue)
    }

    package func union(_ other: MutationArmSet) -> MutationArmSet {
        MutationArmSet(rawValue: rawValue | other.rawValue)
    }
}

/// EXP3 weights over ``MutationArm``, rewarded by corpus admission. See the file header for why EXP3 over discounted UCB.
package struct MutationBandit: Sendable {
    /// The exploration mixture γ: every arm keeps at least γ/4 selection probability no matter how the weights move, so a band can always win back weight after the search moves to a region where it pays again.
    package static let explorationRate = 0.1

    private var weights: [Double]

    /// The arms this bandit draws from, in the order `probabilities` indexes them. Knob-gated inventories are not always a raw-value prefix (the `pairMutation` arms can be enabled without the `graphMutation` arms), so the bandit holds the arm list rather than a count.
    private let arms: [MutationArm]

    /// The distribution over `weights`, recomputed only when a reward moves them. Picks happen once per candidate and rewards once per admission, so computing the distribution per pick allocated an array on every candidate for a value that changes a few times a second at most.
    private var cachedProbabilities: [Double]

    /// `arms` as a set, so a restricted draw can tell in one mask test whether the restriction excludes anything.
    private let inventory: MutationArmSet

    /// Creates a bandit over the given arm inventory. The default covers the band inventory alone.
    package init(arms: [MutationArm] = MutationArm.bandArms) {
        self.arms = arms
        inventory = arms.reduce(into: MutationArmSet.none) { set, arm in
            set.insert(arm)
        }
        weights = Array(repeating: 1.0, count: arms.count)
        cachedProbabilities = Self.probabilities(over: weights)
    }

    /// The current selection probability of each arm: the exploration-smoothed, weight-proportional EXP3 distribution.
    package var probabilities: [Double] {
        cachedProbabilities
    }

    /// The selection probability of one arm, or zero when the arm is outside this bandit's inventory. The trace records a value per arm of the whole inventory, while `probabilities` is indexed by the enabled arms alone.
    package func probability(of arm: MutationArm) -> Double {
        guard let index = arms.firstIndex(of: arm) else {
            return 0
        }
        return cachedProbabilities[index]
    }

    /// The probability one arm is drawn with when the round is restricted to `eligible`: its share of the distribution renormalized over the eligible arms, or zero when the arm is outside either set.
    ///
    /// This is what ``reward(_:drawProbability:)`` needs. The unconditional probability understates it by the eligible mass, so using that instead scales every importance weight by the reciprocal of whatever the gate excluded.
    package func probability(of arm: MutationArm, eligible: MutationArmSet) -> Double {
        guard eligible.contains(arm) else {
            return 0
        }
        var total = 0.0
        for index in arms.indices where eligible.contains(arms[index]) {
            total += cachedProbabilities[index]
        }
        guard total > 0 else {
            return 0
        }
        return probability(of: arm) / total
    }

    private static func probabilities(over weights: [Double]) -> [Double] {
        let totalWeight = weights.reduce(0, +)
        return weights.map { weight in
            (1 - explorationRate) * weight / totalWeight
                + explorationRate / Double(weights.count)
        }
    }

    /// Draws one arm from the current distribution.
    ///
    /// - Parameter random: A uniform draw in [0, 1), supplied by the caller so runs stay deterministic under a pinned seed.
    package func pick(random: Double) -> MutationArm {
        arms[pickIndex(random: random)]
    }

    private func pickIndex(random: Double) -> Int {
        var remaining = random
        var index = 0
        for probability in cachedProbabilities {
            remaining -= probability
            if remaining < 0 {
                return index
            }
            index += 1
        }
        return arms.count - 1
    }

    /// Draws one arm from the eligible subset, renormalizing the distribution over it.
    ///
    /// - Parameters:
    ///   - random: A uniform draw in [0, 1).
    ///   - eligible: Bit set of ``MutationArm`` raw values whose operators can fire on this parent.
    /// - Returns: An eligible arm, or nil when the set excludes every arm this bandit holds.
    package func pick(random: Double, eligible: MutationArmSet) -> MutationArm? {
        draw(random: random, eligible: eligible)?.arm
    }

    /// Draws one arm from the eligible subset and reports the probability the draw ran at, which is what ``reward(_:drawProbability:)`` needs back.
    ///
    /// The eligible mass is summed once and serves both the draw and the probability; asking ``probability(of:eligible:)`` afterwards would sum it again. When the restriction excludes nothing the unconditional distribution is the answer and no mass is summed at all.
    ///
    /// - Returns: The arm and its conditional probability, or nil when the set excludes every arm this bandit holds.
    package func draw(random: Double, eligible: MutationArmSet) -> (arm: MutationArm, probability: Double)? {
        if eligible.intersection(inventory) == inventory {
            let index = pickIndex(random: random)
            return (arms[index], cachedProbabilities[index])
        }
        var total = 0.0
        for index in arms.indices where eligible.contains(arms[index]) {
            total += cachedProbabilities[index]
        }
        guard total > 0 else {
            return nil
        }
        var remaining = random * total
        var last: Int?
        for index in arms.indices where eligible.contains(arms[index]) {
            remaining -= cachedProbabilities[index]
            if remaining < 0 {
                return (arms[index], cachedProbabilities[index] / total)
            }
            // Floating-point drift can leave the running total just short of the draw, so the last eligible arm stands in rather than the caller seeing nil.
            last = index
        }
        guard let last else {
            return nil
        }
        return (arms[last], cachedProbabilities[last] / total)
    }

    /// Credits an arm with one admission reward (x = 1), applying the EXP3 importance-weighted exponential update. Unrewarded picks need no call — a zero reward leaves EXP3 weights unchanged.
    ///
    /// - Parameters:
    ///   - arm: The arm that produced the admitted candidate. An arm outside this bandit's inventory is ignored.
    ///   - drawProbability: The probability that draw ran at, from ``probability(of:eligible:)``. A non-positive value is ignored rather than divided by.
    package mutating func reward(_ arm: MutationArm, drawProbability: Double) {
        guard let index = arms.firstIndex(of: arm), drawProbability > 0 else {
            return
        }
        let armCount = Double(weights.count)
        weights[index] *= exp(Self.explorationRate / (armCount * drawProbability))
        // Rescale before the exponential weights can overflow; the distribution is scale-invariant.
        let totalWeight = weights.reduce(0, +)
        if totalWeight > 1e12 {
            for index in weights.indices {
                weights[index] /= totalWeight
            }
        }
        cachedProbabilities = Self.probabilities(over: weights)
    }
}

package extension MutationArm {
    /// Builds a name-keyed tally over the arm inventory, dropping arms that produced nothing so a report shows only the operators a run actually used.
    static func tally(
        _ ledger: MutationArmLedger,
        _ value: (MutationArmLedger, MutationArm) -> Int
    ) -> [String: Int] {
        var result: [String: Int] = [:]
        for arm in MutationArm.allCases {
            let count = value(ledger, arm)
            if count > 0 {
                result[String(describing: arm)] = count
            }
        }
        return result
    }
}
