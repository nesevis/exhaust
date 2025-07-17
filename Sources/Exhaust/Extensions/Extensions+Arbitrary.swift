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
        Gen.choose(in: range, input: Input.self)
            .bind { length in
                Gen.arrayOf(self, length)
            }
    }
}
//
//// Approach 2: More specific - works with any ReflectiveOperation input type
//extension ReflectiveGenerator {
//    func proliferate<NewInput>(with range: ClosedRange<UInt64>) -> ReflectiveGenerator<NewInput, [Value]> {
//        Gen.choose(in: range, input: NewInput.self)
//            .bind { length in
//                // Use lmap to convert from NewInput to Operation.Input
//                Gen.arrayOf(Gen.lmap({ _ in () as! Operation.Input }, self), length)
//            }
//    }
//}
//
//// Approach 3: Most flexible - preserves original input type
//extension ReflectiveGenerator {
//    func proliferatePreservingInput(with range: ClosedRange<UInt64>) -> ReflectiveGenerator<Operation.Input, [Value]> {
//        Gen.choose(in: range, input: Operation.Input.self)
//            .bind { length in
//                Gen.arrayOf(self, length)
//            }
//    }
//}
