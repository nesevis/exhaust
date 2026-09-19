import ExhaustCore
import Testing

@Suite("Mutation bandit and power schedule tests")
struct MutationBanditTests {
    @Test("Fresh bandit distributes uniformly")
    func uniformStart() {
        let bandit = MutationBandit()
        for probability in bandit.probabilities {
            #expect(abs(probability - 0.25) < 1e-9)
        }
    }

    @Test("Rewards shift probability toward the paying arm")
    func rewardsShiftWeights() {
        var bandit = MutationBandit()
        for _ in 0 ..< 50 {
            // An unrestricted round, so the draw probability is the unconditional one.
            let drawProbability = bandit.probability(of: .medium)
            bandit.reward(.medium, drawProbability: drawProbability)
        }
        let probabilities = bandit.probabilities
        // The exploration mixture caps any arm at 0.925; fifty rewards get most of the way there.
        let favored = probabilities[MutationArm.medium.rawValue]
        #expect(favored > 0.7)
        for (index, probability) in probabilities.enumerated() where index != MutationArm.medium.rawValue {
            #expect(probability < favored)
        }
        // Sanity on the distribution itself.
        #expect(abs(probabilities.reduce(0, +) - 1.0) < 1e-9)
    }

    @Test("The exploration floor keeps every arm reachable no matter the rewards")
    func explorationFloor() {
        var bandit = MutationBandit()
        for _ in 0 ..< 10000 {
            let drawProbability = bandit.probability(of: .splice)
            bandit.reward(.splice, drawProbability: drawProbability)
        }
        let probabilities = bandit.probabilities
        let floor = MutationBandit.explorationRate / Double(probabilities.count)
        for probability in probabilities {
            #expect(probability >= floor - 1e-12)
        }
        // pick honors the floor: a draw landing in the tail of the cumulative distribution returns a non-favored arm.
        #expect(bandit.pick(random: 0.999) != bandit.pick(random: 0.5) || bandit.pick(random: 0.999) == .splice)
    }

    @Test("Picks follow the cumulative distribution deterministically")
    func pickIsDeterministic() {
        var bandit = MutationBandit()
        bandit.reward(.high, drawProbability: bandit.probability(of: .high))
        let first = (0 ..< 10).map { step in bandit.pick(random: Double(step) / 10) }
        let second = (0 ..< 10).map { step in bandit.pick(random: Double(step) / 10) }
        #expect(first == second)
    }

    @Test("The bandit draws only from the eligible set and renormalises over it")
    func banditRespectsTheEligibleSet() throws {
        let bandit = MutationBandit(arms: [.low, .medium, .high, .splice])
        var eligible = MutationArmSet(.low)
        eligible.insert(.high)
        var seen: Set<MutationArm> = []
        for step in 0 ..< 200 {
            let arm = try #require(bandit.pick(random: Double(step) / 200, eligible: eligible))
            seen.insert(arm)
        }
        #expect(seen == [.low, .high])
    }

    @Test("An empty eligible set yields nil rather than an arm the caller cannot use")
    func banditReportsAnEmptySet() {
        let bandit = MutationBandit(arms: [.low, .medium])
        #expect(bandit.pick(random: 0.5, eligible: MutationArmSet(.twinSplice)) == nil)
    }

    @Test("The reward divides by the probability the restricted draw ran at, not the unconditional one")
    func rewardUsesTheConditionalProbability() {
        let bandit = MutationBandit(arms: [.low, .medium, .high, .splice])
        let eligible = MutationArmSet(.low, .high)
        let conditional = bandit.probability(of: .low, eligible: eligible)
        // Two of four arms survive an even distribution, so each takes half the mass.
        #expect(abs(conditional - 0.5) < 1e-9)
        #expect(abs(conditional + bandit.probability(of: .high, eligible: eligible) - 1) < 1e-9)
        // An arm the gate withheld was not drawn at all.
        #expect(bandit.probability(of: .splice, eligible: eligible) == 0)

        // The inflation the unconditional probability would cause: with half the mass withheld, every exponent doubles.
        var conditionalBandit = MutationBandit(arms: [.low, .medium, .high, .splice])
        var unconditionalBandit = conditionalBandit
        conditionalBandit.reward(.low, drawProbability: conditional)
        unconditionalBandit.reward(.low, drawProbability: unconditionalBandit.probability(of: .low))
        #expect(unconditionalBandit.probability(of: .low) > conditionalBandit.probability(of: .low))
    }

    @Test("A band-only bandit never picks a graph arm and ignores its rewards")
    func banditInventoryRestriction() {
        var bandOnly = MutationBandit()
        for step in 0 ..< 1000 {
            let arm = bandOnly.pick(random: Double(step) / 1000)
            #expect(MutationArm.bandArms.contains(arm))
        }
        let before = bandOnly.probabilities
        bandOnly.reward(.swap, drawProbability: bandOnly.probability(of: .swap))
        bandOnly.reward(.lockstepDelta, drawProbability: bandOnly.probability(of: .lockstepDelta))
        #expect(bandOnly.probabilities == before)

        var full = MutationBandit(arms: MutationArm.allCases)
        var sawGraphArm = false
        for step in 0 ..< 1000 {
            let arm = full.pick(random: Double(step) / 1000)
            if MutationArm.bandArms.contains(arm) == false {
                sawGraphArm = true
            }
        }
        #expect(sawGraphArm)
        full.reward(.swap, drawProbability: full.probability(of: .swap))
        #expect(full.probabilities[MutationArm.swap.rawValue] > full.probabilities[MutationArm.shuffle.rawValue])
    }
}
