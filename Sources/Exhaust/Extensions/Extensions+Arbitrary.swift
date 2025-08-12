//
//  Arbitrary.swift
//  Exhaust
//
//  Created by Chris Kolbu on 18/7/2025.
//
//
// Approach 1: Generic over any Input type
extension FreerMonad where Operation == ReflectiveOperation {
    func proliferate(with range: ClosedRange<UInt64>) -> ReflectiveGenerator<[Value]>
    where Operation == ReflectiveOperation {
        Gen.arrayOf(self, Gen.choose(in: range))
    }
}
