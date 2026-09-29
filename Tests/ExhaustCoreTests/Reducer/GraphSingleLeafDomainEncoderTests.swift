//
//  GraphSingleLeafDomainEncoderTests.swift
//  Exhaust
//

import ExhaustTestSupport
import Testing
@testable import ExhaustCore

@Suite("GraphSingleLeafDomainEncoder candidates")
struct GraphSingleLeafDomainEncoderTests {
    @Test("Every candidate lies in the domain and appears once")
    func candidatesAreInDomainAndUnique() throws {
        try exhaustCheck(candidateInputGen, maxIterations: 1000) { input in
            let candidates = input.candidates()
            return candidates.allSatisfy { input.domain.contains($0) }
                && Set(candidates).count == candidates.count
        }
    }

    @Test("The current value is a candidate exactly when it is requested")
    func currentPresentOnlyWhenIncluded() throws {
        try exhaustCheck(candidateInputGen, maxIterations: 1000) { input in
            input.candidates().contains(input.current) == input.includesCurrent
        }
    }

    @Test("Candidate count is the domain size up to the budget, less the excluded current value")
    func candidateCountMatchesDomainAndBudget() throws {
        try exhaustCheck(candidateInputGen, maxIterations: 1000) { input in
            let admissible = input.domain.saturatingCount - (input.includesCurrent ? 0 : 1)
            let expected = min(admissible, UInt64(GraphSingleLeafDomainEncoder.candidateBudget))
            return UInt64(input.candidates().count) == expected
        }
    }

    @Test("Small domains are enumerated in order of distance from the current value")
    func smallDomainsOrderedByDistance() throws {
        try exhaustCheck(candidateInputGen, maxIterations: 1000) { input in
            guard input.domain.saturatingCount <= GraphSingleLeafDomainEncoder.exhaustiveThreshold else {
                return true
            }
            let distances = input.candidates().map { candidate in
                candidate > input.current ? candidate - input.current : input.current - candidate
            }
            return distances == distances.sorted()
        }
    }

    @Test("Large domains try the target and the current value's neighbours first")
    func largeDomainsLeadWithTargetAndNeighbours() throws {
        try exhaustCheck(candidateInputGen, maxIterations: 1000) { input in
            guard input.domain.saturatingCount > GraphSingleLeafDomainEncoder.exhaustiveThreshold else {
                return true
            }
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
            return Array(input.candidates().prefix(expectedPrefix.count)) == expectedPrefix
        }
    }

    @Test("A small domain that does not contain the current value yields no candidates", arguments: [
        (UInt64(10) ... 20, UInt64(5)),
        (UInt64(10) ... 20, UInt64(25)),
        (UInt64.max - 5 ... UInt64.max - 1, UInt64.max),
        (UInt64(1) ... 3, UInt64(0)),
    ])
    func smallDomainWithoutCurrentYieldsNothing(domain: ClosedRange<UInt64>, current: UInt64) {
        let candidates = GraphSingleLeafDomainEncoder.candidates(
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
        GraphSingleLeafDomainEncoder.candidates(
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
