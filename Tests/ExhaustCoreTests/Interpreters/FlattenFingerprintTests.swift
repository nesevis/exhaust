import Testing
@testable import ExhaustCore

@Suite("Flatten fingerprint preservation")
struct FlattenFingerprintTests {
    @Test("Branch entries keep their pick-site fingerprint through flattening")
    func flattenPreservesBranchFingerprint() throws {
        // Swarm masking keys per-site masks on the fingerprint; flatten dropping it silently disables masking for every pick site (found 2026-07-11 when the first swarm arm no-opped).
        let gen = Gen.pick(choices: [
            (1, Gen.choose(in: 0 ... 3 as ClosedRange<Int>).erase()),
            (1, Gen.choose(in: 10 ... 13 as ClosedRange<Int>).erase()),
        ])
        var interpreter = ValueAndChoiceTreeInterpreter(gen, materializePicks: false, seed: 1, maxRuns: 3)
        let (_, tree) = try #require(try interpreter.next())
        let branches = ChoiceSequence.flatten(tree).compactMap { entry -> ChoiceSequenceValue.Branch? in
            guard case let .branch(branch) = entry else {
                return nil
            }
            return branch
        }
        #expect(branches.isEmpty == false)
        #expect(branches.allSatisfy { $0.fingerprint != 0 })
    }
}
