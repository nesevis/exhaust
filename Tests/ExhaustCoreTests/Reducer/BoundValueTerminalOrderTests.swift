import Testing
@testable import ExhaustCore

@Suite("Bound value terminal admission")
struct BoundValueTerminalOrderTests {
    @Test("A rejected fixed prefix has no improving value completion")
    func pruningPreservesAllImprovements() {
        // Structure can appear before or between values. Only the suffix values vary; its structural template stays fixed as terminal search requires.
        let templates: [[ChoiceSequenceValue]] = [
            [.just, Self.value(0), Self.value(0), .just],
            [Self.value(0), .group(true), Self.value(0), .group(false)],
            [.sequence(true), Self.value(0), .sequence(false), Self.value(0)],
        ]
        let sequences = templates.flatMap { template in
            (UInt64(0) ... 2).flatMap { first in
                (UInt64(0) ... 2).map { second in
                    var result = ChoiceSequence(template)
                    let positions = result.indices.filter { result[$0].value != nil }
                    result[positions[0]] = Self.value(first)
                    result[positions[1]] = Self.value(second)
                    return result
                }
            }
        }
        for incumbent in sequences {
            for candidate in sequences {
                for end in 0 ... candidate.count {
                    guard BoundValueTerminalOrder.canImprove(candidate, fixedBefore: end, incumbent: incumbent) == false else {
                        continue
                    }
                    for completion in sequences {
                        let sameTemplate = candidate.indices.allSatisfy { index in
                            if candidate[index].value != nil, completion[index].value != nil {
                                return index >= end || candidate[index] == completion[index]
                            }
                            return candidate[index] == completion[index]
                        }
                        if sameTemplate {
                            #expect(completion.shortLexPrecedes(incumbent) == false)
                        }
                    }
                }
            }
        }
    }

    @Test("Length wins even when the fixed controller is larger")
    func shorterSequenceRemainsAdmissible() {
        let incumbent = ChoiceSequence([Self.value(1), Self.value(9), .just])
        let shorter = ChoiceSequence([Self.value(2), Self.value(9)])
        #expect(BoundValueTerminalOrder.canImprove(shorter, fixedBefore: 1, incumbent: incumbent))
        #expect(BoundValueTerminalOrder.canImprove(incumbent, fixedBefore: 1, incumbent: shorter) == false)
    }

    private static func value(_ value: UInt64) -> ChoiceSequenceValue {
        .value(.init(choice: ChoiceValue(value, tag: .uint64), validRange: 0 ... 9))
    }
}
