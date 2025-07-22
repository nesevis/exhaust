//
//  Arbitrary.swift
//  Exhaust
//
//  Created by Chris Kolbu on 18/7/2025.
//
//
// Approach 1: Generic over any Input type
extension FreerMonad where Operation: AnyReflectiveOperation {
    func proliferate<Input>(with range: ClosedRange<UInt64>) -> ReflectiveGenerator<Input, [Value]> 
    where Operation == ReflectiveOperation<Input> {
        Gen.arrayOf(self, Gen.choose(in: range, input: Input.self))
    }
}
