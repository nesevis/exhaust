import Testing
@testable import ExhaustCore

@Suite("Materializer fallback leaf reuse")
struct MaterializerLeafReuseTests {
    @Test("Resolved leaves retain fresh metadata", arguments: [false, true], [false, true])
    func freshMetadata(isRangeExplicit: Bool, isPinnedToSize: Bool) throws {
        let fallback = ChoiceTree.choice(
            ChoiceValue(UInt64(7), tag: .uint64),
            ChoiceMetadata(validRange: 0 ... 10, isRangeExplicit: false)
        )
        var context = Materializer.Context(
            prefix: .init([]),
            mode: .guided(seed: 42, fallbackTree: fallback)
        )
        let resolved = try Materializer.resolveChooseBits(
            min: 0,
            max: 10,
            tag: .uint64,
            isRangeExplicit: isRangeExplicit,
            scaling: isPinnedToSize ? .size : nil,
            typeTagPayload: nil,
            context: &context,
            calleeFallback: fallback
        )
        guard case let .choice(choice, metadata) = resolved.tree else {
            Issue.record("Expected a resolved leaf")
            return
        }
        #expect(choice == ChoiceValue(UInt64(7), tag: .uint64))
        #expect(metadata == ChoiceMetadata(
            validRange: 0 ... 10,
            isRangeExplicit: isRangeExplicit,
            isPinnedToSize: isPinnedToSize
        ))
        #expect(context.decodingReport?.fallbackResolutionCount == 1)
    }

    @Test("Unchanged values still acquire the current range")
    func freshRange() throws {
        let fallback = ChoiceTree.choice(
            ChoiceValue(UInt64(7), tag: .uint64),
            ChoiceMetadata(validRange: 0 ... 100)
        )
        var context = Materializer.Context(prefix: .init([]), mode: .guided(seed: 42, fallbackTree: fallback))
        let resolved = try Materializer.resolveChooseBits(
            min: 0,
            max: 10,
            tag: .uint64,
            isRangeExplicit: false,
            scaling: nil,
            typeTagPayload: nil,
            context: &context,
            calleeFallback: fallback
        )
        guard case let .choice(choice, metadata) = resolved.tree else {
            Issue.record("Expected a resolved leaf")
            return
        }
        #expect(choice == ChoiceValue(UInt64(7), tag: .uint64))
        #expect(metadata.validRange == 0 ... 10)
    }

    @Test("Matching fallback leaves do not override a changed prefix or its tag")
    func prefixTakesPrecedence() throws {
        let metadata = ChoiceMetadata(validRange: 0 ... 10, isRangeExplicit: true)
        let fallback = ChoiceTree.choice(ChoiceValue(UInt64(7), tag: .uint64), metadata)
        let prefixChoices = [
            ChoiceValue(UInt64(7), tag: .uint64),
            ChoiceValue(UInt64(3), tag: .uint64),
            ChoiceValue(UInt64(7), tag: .uint8),
            ChoiceValue(UInt64(20), tag: .uint64),
        ]
        for prefixChoice in prefixChoices {
            var context = Materializer.Context(
                prefix: .init([.value(.init(choice: prefixChoice, validRange: 0 ... 100))]),
                mode: .guided(seed: 42, fallbackTree: fallback)
            )
            let resolved = try Materializer.resolveChooseBits(
                min: 0,
                max: 10,
                tag: .uint64,
                isRangeExplicit: true,
                scaling: nil,
                typeTagPayload: nil,
                context: &context,
                calleeFallback: fallback
            )
            guard case let .choice(choice, freshMetadata) = resolved.tree else {
                Issue.record("Expected a resolved leaf")
                return
            }
            #expect(choice.bitPattern64 == min(prefixChoice.bitPattern64, 10))
            #expect(choice.tag == (prefixChoice.bitPattern64 <= 10 ? prefixChoice.tag : .uint64))
            #expect(freshMetadata == metadata)
            #expect(context.decodingReport?.totalCount == 1)
            #expect(context.decodingReport?.fidelity == 1)
            var expectedRandom = Xoshiro256(seed: 42)
            #expect(context.prng.next() == expectedRandom.next())
        }
    }

    @Test("Fallback values clamp and adopt the current generator tag")
    func fallbackClampsAndRetags() throws {
        let fallback = ChoiceTree.choice(
            ChoiceValue(UInt64(7), tag: .uint8),
            ChoiceMetadata(validRange: 0 ... 100)
        )
        for maximum in [UInt64(5), 10] {
            var context = Materializer.Context(prefix: .init([]), mode: .guided(seed: 42, fallbackTree: fallback))
            let resolved = try Materializer.resolveChooseBits(
                min: 0,
                max: maximum,
                tag: .uint64,
                isRangeExplicit: true,
                scaling: nil,
                typeTagPayload: nil,
                context: &context,
                calleeFallback: fallback
            )
            guard case let .choice(choice, metadata) = resolved.tree else {
                Issue.record("Expected a resolved leaf")
                return
            }
            #expect(choice == ChoiceValue(min(7, maximum), tag: .uint64))
            #expect(metadata.validRange == 0 ... maximum)
            #expect(metadata.isRangeExplicit)
        }
    }

    @Test("Character payloads are refreshed when the value and range are unchanged")
    func freshCharacterPayload() throws {
        let oldPayload = TypeTagPayload.character(problematicIndices: [1], simplifications: .empty)
        let newPayload = TypeTagPayload.character(problematicIndices: [2], simplifications: .empty)
        let fallback = ChoiceTree.choice(
            ChoiceValue(UInt64(7), tag: .character),
            ChoiceMetadata(validRange: 0 ... 10, isRangeExplicit: true, typeTagPayload: oldPayload)
        )
        for payload in [newPayload, nil] {
            var context = Materializer.Context(prefix: .init([]), mode: .guided(seed: 42, fallbackTree: fallback))
            let resolved = try Materializer.resolveChooseBits(
                min: 0,
                max: 10,
                tag: .character,
                isRangeExplicit: true,
                scaling: nil,
                typeTagPayload: payload,
                context: &context,
                calleeFallback: fallback
            )
            guard case let .choice(choice, metadata) = resolved.tree else {
                Issue.record("Expected a resolved leaf")
                return
            }
            #expect(choice == ChoiceValue(UInt64(7), tag: .character))
            #expect(metadata.typeTagPayload == payload)
            #expect(context.decodingReport?.fallbackResolutionCount == 1)
        }
    }
}
