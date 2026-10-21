//
//  LeafCandidatesTests.swift
//  Exhaust
//

import ExhaustTestSupport
import Testing
@testable import ExhaustCore

@Suite("Leaf proposal candidates")
struct LeafCandidatesTests {
    @Test("Candidates obey domain, budget, inclusion and ordering contracts")
    func candidateContract() throws {
        var smallDomains = 0
        var largeDomains = 0
        try exhaustCheck(candidateInputGen, maxIterations: 1000) { input in
            let candidates = input.candidates()
            let admissible = input.domain.saturatingCount - (input.includesCurrent ? 0 : 1)
            #expect(candidates.allSatisfy { input.domain.contains($0) })
            #expect(Set(candidates).count == candidates.count)
            #expect(candidates.contains(input.current) == input.includesCurrent)
            #expect(UInt64(candidates.count) == min(admissible, UInt64(LeafCandidates.candidateBudget)))
            if input.domain.saturatingCount <= LeafCandidates.exhaustiveThreshold {
                smallDomains += 1
                let distances = candidates.map { $0 > input.current ? $0 - input.current : input.current - $0 }
                return distances == distances.sorted()
            }
            largeDomains += 1
            var expectedPrefix: [UInt64] = input.includesCurrent ? [input.current] : []
            var leading = [input.target]
            if input.current > input.domain.lowerBound {
                leading.append(input.current - 1)
            }
            if input.current < input.domain.upperBound {
                leading.append(input.current + 1)
            }
            for value in leading where value != input.current && expectedPrefix.contains(value) == false {
                expectedPrefix.append(value)
            }
            return Array(candidates.prefix(expectedPrefix.count)) == expectedPrefix
        }
        #expect(smallDomains > 0)
        #expect(largeDomains > 0)
    }

    @Test("The first neighbour reduces signed magnitude in either direction", arguments: [Int64(-5), 5])
    func signedNeighbourMovesTowardTarget(value: Int64) throws {
        let bounds: ClosedRange<Int64> = switch value < 0 {
            case true:
                -9 ... -1
            case false:
                1 ... 9
        }
        let lowerBound = ChoiceValue(bounds.lowerBound, tag: .int64).bitPattern64
        let upperBound = ChoiceValue(bounds.upperBound, tag: .int64).bitPattern64
        let domain = lowerBound ... upperBound
        let current = ChoiceValue(value, tag: .int64)
        let candidates = LeafCandidates.candidates(
            in: domain,
            current: current.bitPattern64,
            target: current.reductionTarget(in: domain),
            includesCurrent: false
        )
        let first = try #require(candidates.first)
        let proposed = ChoiceValue(TypeTag.int64.makeConvertible(bitPattern64: first), tag: .int64)
        #expect(proposed.shortlexKey < current.shortlexKey)
    }

    @Test("A small domain that does not contain the current value yields no candidates", arguments: [
        (UInt64(10) ... 20, UInt64(5)),
        (UInt64(10) ... 20, UInt64(25)),
        (UInt64.max - 5 ... UInt64.max - 1, UInt64.max),
        (UInt64(1) ... 3, UInt64(0)),
    ])
    func smallDomainWithoutCurrentYieldsNothing(domain: ClosedRange<UInt64>, current: UInt64) {
        let candidates = LeafCandidates.candidates(
            in: domain,
            current: current,
            target: domain.lowerBound,
            includesCurrent: false
        )
        #expect(candidates.isEmpty)
    }
}

// MARK: - Helpers

private struct CandidateInput: CustomStringConvertible {
    let domain: ClosedRange<UInt64>
    let current: UInt64
    let target: UInt64
    let includesCurrent: Bool

    var description: String {
        "domain: \(domain), current: \(current), target: \(target), includesCurrent: \(includesCurrent)"
    }

    func candidates() -> [UInt64] {
        LeafCandidates.candidates(
            in: domain,
            current: current,
            target: target,
            includesCurrent: includesCurrent
        )
    }
}

/// Domains straddle the exhaustive threshold and the candidate budget, and sit at both ends of `UInt64` so overflow at the bounds is exercised. Current and target always lie inside the domain.
private let candidateInputGen: Generator<CandidateInput> = {
    let lowerBound = Gen.pick(choices: [
        (1, Gen.choose(in: UInt64(0) ... 100)),
        (1, Gen.choose(in: UInt64.max - 100 ... UInt64.max)),
        (1, Gen.choose(in: UInt64.min ... UInt64.max)),
    ])
    let width = Gen.pick(choices: [
        (2, Gen.choose(in: UInt64(0) ... 70)),
        (1, Gen.choose(in: UInt64.min ... UInt64.max)),
    ])
    return Gen.zip(
        lowerBound,
        width,
        Gen.choose(in: UInt64.min ... UInt64.max),
        Gen.choose(in: UInt64.min ... UInt64.max),
        Gen.choose(in: UInt64(0) ... 1)
    ).map { lowerBound, width, currentSeed, targetSeed, includesCurrentFlag in
        let span = min(width, UInt64.max - lowerBound)
        let domain = lowerBound ... lowerBound + span
        return CandidateInput(
            domain: domain,
            current: lowerBound + offset(from: currentSeed, within: span),
            target: lowerBound + offset(from: targetSeed, within: span),
            includesCurrent: includesCurrentFlag == 1
        )
    }
}()

private func offset(from seed: UInt64, within span: UInt64) -> UInt64 {
    guard span < UInt64.max else {
        return seed
    }
    return seed % (span + 1)
}
