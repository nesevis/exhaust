// Adaptive mutation-arm selection for the mutation phase.
//
// A uniform draw over the intensity bands is the naive default the literature beats twice over: stacking several operators per child outperforms one-at-a-time (Wu et al., "One Fuzzing Strategy to Rule Them All", ICSE 2022), and the right operator weights vary by target, so any fixed tuning loses to an adaptive one (same paper; MOpt, USENIX Security 2019). The bandit here is EXP3 (exponential-weight exploration/exploitation), chosen over discounted UCB because the reward signal — corpus admission — is sparse and non-stationary in exactly the way EXP3's adversarial guarantees tolerate: admission rates collapse as coverage saturates, and a band that stops paying should decay rather than coast on stale confidence intervals.
//
// One deviation from textbook EXP3: the update uses the arm's selection probability at reward time rather than at pick time. Weights move only on admissions, which are rare relative to picks, so the drift between the two should be small, and it is unmeasured. Each child comes from exactly one arm, so the reward lands on the arm that produced it; stacked children, which would have made this a combinatorial bandit problem, were removed after measuring neutral-to-worse.
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

/// EXP3 weights over ``MutationArm``, rewarded by corpus admission. See the file header for why EXP3 over discounted UCB.
package struct MutationBandit: Sendable {
    /// The exploration mixture γ: every arm keeps at least γ/4 selection probability no matter how the weights move, so a band can always win back weight after the search moves to a region where it pays again.
    package static let explorationRate = 0.1

    private var weights: [Double]

    /// The arms this bandit draws from, in the order `probabilities` indexes them. Knob-gated inventories are not always a raw-value prefix (the `pairMutation` arms can be enabled without the `graphMutation` arms), so the bandit holds the arm list rather than a count.
    private let arms: [MutationArm]

    /// The distribution over `weights`, recomputed only when a reward moves them. Picks happen once per candidate and rewards once per admission, so computing the distribution per pick allocated an array on every candidate for a value that changes a few times a second at most.
    private var cachedProbabilities: [Double]

    /// Creates a bandit over the given arm inventory. The default covers the band inventory alone.
    package init(arms: [MutationArm] = MutationArm.bandArms) {
        self.arms = arms
        weights = Array(repeating: 1.0, count: arms.count)
        cachedProbabilities = Self.probabilities(over: weights)
    }

    /// The current selection probability of each arm: the exploration-smoothed, weight-proportional EXP3 distribution.
    package var probabilities: [Double] {
        cachedProbabilities
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
        var remaining = random
        for (index, probability) in probabilities.enumerated() {
            remaining -= probability
            if remaining < 0 {
                return arms[index]
            }
        }
        return arms[arms.count - 1]
    }

    /// Credits an arm with one admission reward (x = 1), applying the EXP3 importance-weighted exponential update. Unrewarded picks need no call — a zero reward leaves EXP3 weights unchanged. An arm outside this bandit's inventory is ignored.
    package mutating func reward(_ arm: MutationArm) {
        guard let index = arms.firstIndex(of: arm) else {
            return
        }
        let probability = probabilities[index]
        let armCount = Double(weights.count)
        weights[index] *= exp(Self.explorationRate / (armCount * probability))
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
