//
//  StructuralEqualityReflexivityTests.swift
//  Exhaust
//
//  Every value the linearizability checker can meet as a command response must compare equal to itself:
//  a reflexivity failure fabricates a response mismatch out of a correct concurrent run. The generated
//  domain deliberately spans the shapes structurallyEqual decides through different rules — payload-free
//  cases, payload cases, Equatable leaves, and possibly-empty collections of non-Equatable elements.
//

import Exhaust
import ExhaustCore
import Testing

@Suite("Structural equality reflexivity")
struct StructuralEqualityReflexivityTests {
    @Test("Every generated value is structurally equal to itself")
    func everyGeneratedValueIsStructurallyEqualToItself() {
        let payloadFreeGen = #gen(.element(from: [Shape.empty, Shape.reset]))
        let scalarGen = #gen(.int(in: -100 ... 100)) { Shape.scalar($0) }
        let pairGen = #gen(.int(in: -100 ... 100), .asciiString(length: 0 ... 5)) { Shape.pair(key: $0, name: $1) }
        let listGen = #gen(.int(in: -100 ... 100).array(length: 0 ... 4)) { Shape.list($0) }
        let groupGen = #gen(scalarGen.array(length: 0 ... 3)) { Shape.group($0) }
        let shapeGen = #gen(.oneOf(payloadFreeGen, scalarGen, pairGen, listGen, groupGen))

        #exhaust(shapeGen) { shape in
            structurallyEqual(shape, shape)
        }
    }
}

// MARK: - Supporting Types

/// Deliberately non-Equatable: an Equatable type short-circuits to `==` and never reaches the Mirror walk under test.
private enum Shape: Hashable, Sendable {
    case empty
    case reset
    case scalar(Int)
    case pair(key: Int, name: String)
    case list([Int])
    case group([Shape])
}
