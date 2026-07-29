//
//  StructuralEqualityTests.swift
//  Exhaust
//
//  Pins the three comparison rules the linearizability checker depends on: values of different dynamic types
//  are never equal, an enum's case name is part of its identity, and a value that decomposes to no children
//  is still comparable. Without the second, two commands with matching argument shapes are indistinguishable
//  responses; without the third, a payload-free case or an empty collection compares unequal to itself and a
//  correct concurrent run is reported as a response mismatch.
//

import ExhaustCore
import Testing

@Suite("Structural equality")
struct StructuralEqualityTests {
    // MARK: - Enum Case Identity

    @Test("Distinct cases carrying the same payload shape are not equal")
    func distinctCasesWithMatchingPayloadShapeAreNotEqual() {
        #expect(structurallyEqual(Operation.delete(key: 0), Operation.getOrElse(key: 0)) == false)
    }

    @Test("One case with equal payloads is equal")
    func oneCaseWithEqualPayloadsIsEqual() {
        #expect(structurallyEqual(Operation.delete(key: 0), Operation.delete(key: 0)))
        #expect(structurallyEqual(Operation.update(key: 0, value: 2), Operation.update(key: 0, value: 2)))
    }

    @Test("One case with differing payloads is not equal")
    func oneCaseWithDifferingPayloadsIsNotEqual() {
        #expect(structurallyEqual(Operation.delete(key: 0), Operation.delete(key: 1)) == false)
        #expect(structurallyEqual(Operation.update(key: 0, value: 2), Operation.update(key: 0, value: 3)) == false)
    }

    // MARK: - Type Identity

    @Test("Cases of different enum types with the same name and payload are not equal")
    func casesOfDifferentEnumTypesWithSameNameAndPayloadAreNotEqual() {
        #expect(structurallyEqual(Operation.delete(key: 0), OtherOperation.delete(key: 0)) == false)
    }

    @Test("Structs of different types with the same field names and values are not equal")
    func structsOfDifferentTypesWithSameFieldNamesAndValuesAreNotEqual() {
        #expect(structurallyEqual(Boxed(first: 1, second: "a"), Duplicated(first: 1, second: "a")) == false)
    }

    // MARK: - Childless Values

    @Test("A payload-free case is equal to itself")
    func payloadFreeCaseIsEqualToItself() {
        #expect(structurallyEqual(Operation.clear, Operation.clear))
    }

    @Test("Two distinct payload-free cases are not equal")
    func distinctPayloadFreeCasesAreNotEqual() {
        #expect(structurallyEqual(Operation.clear, Operation.reset) == false)
    }

    @Test("Two empty structs of one type are equal")
    func emptyStructsOfOneTypeAreEqual() {
        #expect(structurallyEqual(Marker(), Marker()))
    }

    @Test("Empty structs of different types are not equal")
    func emptyStructsOfDifferentTypesAreNotEqual() {
        #expect(structurallyEqual(Marker(), OtherMarker()) == false)
    }

    @Test("Two empty tuples are equal")
    func emptyTuplesAreEqual() {
        #expect(structurallyEqual((), ()))
    }

    @Test("Two instances of an opaque class are not equal")
    func opaqueClassInstancesAreNotEqual() {
        #expect(structurallyEqual(Opaque(), Opaque()) == false)
    }

    @Test("Two empty arrays of a non-Equatable element type are equal")
    func emptyArraysOfNonEquatableElementTypeAreEqual() {
        #expect(structurallyEqual([Opaque](), [Opaque]()))
    }

    @Test("Two empty dictionaries of a non-Equatable value type are equal")
    func emptyDictionariesOfNonEquatableValueTypeAreEqual() {
        #expect(structurallyEqual([Int: Opaque](), [Int: Opaque]()))
    }

    @Test("An empty array is not equal to a populated one")
    func emptyArrayIsNotEqualToPopulatedArray() {
        #expect(structurallyEqual([Opaque](), [Opaque()]) == false)
    }

    @Test("Empty arrays of different element types are not equal")
    func emptyArraysOfDifferentElementTypesAreNotEqual() {
        #expect(structurallyEqual([Opaque](), [Marker]()) == false)
    }

    // MARK: - Preserved Behavior

    @Test("Non-Equatable compound values compare field by field")
    func nonEquatableCompoundValuesCompareFieldByField() {
        #expect(structurallyEqual(Boxed(first: 1, second: "a"), Boxed(first: 1, second: "a")))
        #expect(structurallyEqual(Boxed(first: 1, second: "a"), Boxed(first: 2, second: "a")) == false)
    }

    @Test("Tuples compare element by element")
    func tuplesCompareElementByElement() {
        #expect(structurallyEqual((1, "a"), (1, "a")))
        #expect(structurallyEqual((1, "a"), (1, "b")) == false)
    }

    // MARK: - Field Names Are Part Of Identity

    @Test("A labelled tuple is not equal to an unlabelled one with the same elements")
    func labelledTupleIsNotEqualToUnlabelledTuple() {
        #expect(structurallyEqual((1, 2), (first: 1, second: 2)) == false)
    }

    @Test("Same-shaped structs with different field names are not equal")
    func sameShapedStructsWithDifferentFieldNamesAreNotEqual() {
        #expect(structurallyEqual(Boxed(first: 1, second: "a"), Relabelled(third: 1, fourth: "a")) == false)
    }

    @Test("Equatable leaves take the exact comparison path")
    func equatableLeavesTakeTheExactComparisonPath() {
        #expect(structurallyEqual(1, 1))
        #expect(structurallyEqual(1, 2) == false)
    }

    @Test("Two nils are equal and a nil is never equal to a value")
    func nilsAreEqualToEachOtherOnly() {
        #expect(structurallyEqual(Int?.none as Any, Int?.none as Any))
        #expect(structurallyEqual(Int?.none as Any, 0) == false)
    }

    @Test("One-sided optional boxing is peeled before comparison")
    func oneSidedOptionalBoxingIsPeeled() {
        #expect(structurallyEqual(Int?.some(1) as Any, 1))
        #expect(structurallyEqual(Operation?.some(.clear) as Any, Operation.clear))
    }
}

// MARK: - Fixtures

//
// Deliberately non-Equatable: an Equatable type short-circuits to `==` and never reaches the Mirror walk
// these tests cover.

private enum Operation {
    case delete(key: Int)
    case getOrElse(key: Int)
    case update(key: Int, value: Int)
    case clear
    case reset
}

/// Mirrors ``Operation``'s `delete` case under a different type, so only the dynamic type distinguishes the two.
private enum OtherOperation {
    case delete(key: Int)
}

private struct Marker {}

private struct OtherMarker {}

private struct Boxed {
    let first: Int
    let second: String
}

/// Mirrors ``Boxed``'s field types under different names, so only the labels distinguish the two.
private struct Relabelled {
    let third: Int
    let fourth: String
}

/// Mirrors ``Boxed`` exactly under a different type, so only the dynamic type distinguishes the two.
private struct Duplicated {
    let first: Int
    let second: String
}

private final class Opaque {}
