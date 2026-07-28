//
//  HotPathLayoutTests.swift
//  Exhaust
//

import Testing
@testable import ExhaustCore

/// Guards the in-memory size of the values the interpreters allocate, copy, and destroy once per generation decision.
///
/// None of these assertions can be derived from behavior. A violation costs throughput and nothing else, so no functional test fails and no reviewer sees a symptom. That is the whole reason they are written down.
///
/// ``ChoiceTree``, ``FreerMonad``, and ``EncoderDispatch`` are `indirect` for performance, but each is also recursive, so the compiler already refuses to drop the keyword. What is left unguarded for those three is the width the boxing buys: the case tag rides in the pointer's spare bits, and past roughly 64 payload cases it no longer fits, doubling the stride of every array of them.
///
/// The payload budgets matter more, because that is where the cost actually accrued once before. Boxing hides a payload from the enum's own size, so a payload can grow without any of the pointer-width assertions moving. Inlining ``TypeTagPayload`` into ``ChoiceMetadata`` took the `.choice` box from 48 to 113 bytes and the `.sequence` box from 40 to 105, and cost roughly 15% across the ECOOP suite, uniformly, in workloads that generate no dates at all (measured 2026-07-28 against the 0.17.4 baseline).
///
/// The mechanism worth remembering: ``DateGrid`` stores Foundation's `Calendar`, and non-frozen types have no compile-time layout. Storing one anywhere reachable from these types propagates that opacity transitively, replacing constant-size allocation and inline copies with runtime metadata instantiation and value-witness calls. `Calendar`, `TimeZone`, `Locale`, `URL`, and `Data` all behave this way.
///
/// Sizes are asserted in pointer-width terms rather than as literals, so the suite holds on 32-bit targets. The budgets are ceilings with deliberate headroom, not descriptions of the current layout.
@Suite("Hot path layout")
struct HotPathLayoutTests {
    // MARK: - Boxed enum width

    @Test("ChoiceTree stays pointer sized")
    func choiceTreeIsPointerSized() {
        #expect(MemoryLayout<ChoiceTree>.size == pointerSize)
    }

    @Test("FreerMonad stays pointer sized regardless of its value type")
    func freerMonadIsPointerSized() {
        #expect(MemoryLayout<Generator<Int>>.size == pointerSize)
        #expect(MemoryLayout<Generator<String>>.size == pointerSize)
        #expect(MemoryLayout<Generator<[Double]>>.size == pointerSize)
        #expect(MemoryLayout<AnyGenerator>.size == pointerSize)
    }

    @Test("EncoderDispatch stays pointer sized as encoder cases are added")
    func encoderDispatchIsPointerSized() {
        #expect(MemoryLayout<EncoderDispatch>.size == pointerSize)
    }

    // MARK: - Boxed payload budgets

    @Test("The choice node payload stays within eight pointers")
    func choicePayloadFitsItsBudget() {
        #expect(MemoryLayout<(ChoiceValue, ChoiceMetadata)>.size <= 8 * pointerSize)
    }

    @Test("The sequence node payload stays within six pointers")
    func sequencePayloadFitsItsBudget() {
        #expect(MemoryLayout<([ChoiceTree], ChoiceMetadata)>.size <= 6 * pointerSize)
    }

    // MARK: - TypeTagPayload and ChoiceMetadata

    @Test("TypeTagPayload is boxed rather than inlined")
    func typeTagPayloadIsBoxed() {
        #expect(MemoryLayout<TypeTagPayload>.size == pointerSize)
    }

    @Test("An absent TypeTagPayload costs no discriminator byte")
    func absentPayloadPacksIntoSpareBits() {
        #expect(MemoryLayout<TypeTagPayload?>.size == MemoryLayout<TypeTagPayload>.size)
    }

    @Test("ChoiceMetadata fits within a valid range plus one pointer")
    func choiceMetadataFitsItsBudget() {
        let budget = MemoryLayout<ClosedRange<UInt64>?>.stride + pointerSize
        #expect(MemoryLayout<ChoiceMetadata>.size <= budget)
    }

    // MARK: - Helpers

    /// The width the boxed enums above are expected to collapse to.
    private var pointerSize: Int {
        MemoryLayout<UnsafeRawPointer>.size
    }
}
