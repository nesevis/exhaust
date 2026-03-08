//
//  ConstraintViolationTests.swift
//  ExhaustTests
//
//  Tests to ensure that constrained generators never produce values
//  that violate their specified constraints.
//

import ExhaustCore
import Testing
@testable import Exhaust

@Suite("Constraint Violation Prevention")
struct ConstraintViolationTests {
    @Test("Range-constrained generators never exceed bounds")
    func rangeBoundsNeverViolated() {
        #exhaust(#gen(.int(in: 10 ... 50))) { value in
            value >= 10 && value <= 50
        }
    }

    @Test("Array size constraints never violated")
    func arraySizeConstraintsNeverViolated() {
        #exhaust(#gen(.int().array(length: 3 ... 7))) { array in
            array.count >= 3 && array.count <= 7
        }
    }

    @Test("Filtered generators never produce filtered values")
    func filteredGeneratorsNeverViolate() {
        let gen = #gen(.int(in: -1000 ... 1000)).filter { $0 % 2 == 0 }
        #exhaust(gen) { value in
            value % 2 == 0
        }
    }

    @Test("Mapped generators preserve constraints")
    func mappedGeneratorConstraints() {
        let gen = #gen(.int(in: 0 ... 1000)).map { $0 + 1 }
        #exhaust(gen) { value in
            value > 0
        }
    }

    @Test("Bound generators respect all constraints")
    func boundGeneratorConstraints() {
        let gen = #gen(.int(in: 1 ... 100)).bind { first in
            Gen.choose(in: (first + 1) ... 200).map { (first, $0) }
        }
        #exhaust(gen) { first, second in
            second > first && first >= 1 && first <= 100 && second <= 200
        }
    }

    @Test("String length constraints never violated")
    func stringLengthConstraints() {
        #exhaust(#gen(.asciiString(length: 1 ... 10))) { str in
            str.count >= 1 && str.count <= 10
        }
    }

    @Test("Zipped generators maintain individual constraints")
    func zippedGeneratorConstraints() {
        let evenGen = #gen(.int(in: 0 ... 50)).map { $0 * 2 }
        let gen = #gen(.int(in: 1 ... 100), evenGen, .string().array(length: 1 ... 3))
        #exhaust(gen) { positive, even, array in
            positive >= 1 && positive <= 100
                && even % 2 == 0 && even >= 0 && even <= 100
                && array.count >= 1 && array.count <= 3
        }
    }
}
