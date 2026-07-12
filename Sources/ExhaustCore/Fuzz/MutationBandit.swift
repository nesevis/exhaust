// Adaptive mutation-arm selection for the mutation phase.
//
// A uniform draw over the intensity bands is the naive default the literature beats twice over:
// stacking several operators per child outperforms one-at-a-time (Wu et al., "One Fuzzing
// Strategy to Rule Them All", ICSE 2022), and the right operator weights vary by target, so any
// fixed tuning loses to an adaptive one (same paper; MOpt, USENIX Security 2019). The bandit
// here is EXP3 (exponential-weight exploration/exploitation), chosen over discounted UCB because
// the reward signal — corpus admission — is sparse and non-stationary in exactly the way EXP3's
// adversarial guarantees tolerate: admission rates collapse as coverage saturates, and a band
// that stops paying should decay rather than coast on stale confidence intervals.
//
// One engineering deviation from textbook EXP3: with stacked mutations several arms contribute
// to one child, and the reward arrives only after the child's evaluation. The update uses the
// arm's selection probability at reward time rather than at pick time — weights move only on
// admissions, which are rare relative to picks, so the drift between the two is negligible.

import Foundation

/// One selectable mutation operator: the three intensity bands plus the bind-boundary splice.
package enum MutationArm: Int, CaseIterable, Sendable {
    case low = 0
    case medium = 1
    case high = 2
    case splice = 3
}

/// EXP3 weights over ``MutationArm``, rewarded by corpus admission. See the file header for why EXP3 over discounted UCB.
package struct MutationBandit: Sendable {
    /// The exploration mixture γ: every arm keeps at least γ/4 selection probability no matter how the weights move, so a band can always win back weight after the search moves to a region where it pays again.
    package static let explorationRate = 0.1

    private var weights: [Double] = Array(repeating: 1.0, count: MutationArm.allCases.count)

    package init() {}

    /// The current selection probability of each arm: the exploration-smoothed, weight-proportional EXP3 distribution.
    package var probabilities: [Double] {
        let totalWeight = weights.reduce(0, +)
        return weights.map { weight in
            (1 - Self.explorationRate) * weight / totalWeight
                + Self.explorationRate / Double(weights.count)
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
                return MutationArm.allCases[index]
            }
        }
        return .splice
    }

    /// Credits an arm with one admission reward (x = 1), applying the EXP3 importance-weighted exponential update. Unrewarded picks need no call — a zero reward leaves EXP3 weights unchanged.
    package mutating func reward(_ arm: MutationArm) {
        let probability = probabilities[arm.rawValue]
        let armCount = Double(weights.count)
        weights[arm.rawValue] *= exp(Self.explorationRate / (armCount * probability))
        // Rescale before the exponential weights can overflow; the distribution is scale-invariant.
        let totalWeight = weights.reduce(0, +)
        if totalWeight > 1e12 {
            for index in weights.indices {
                weights[index] /= totalWeight
            }
        }
    }
}
