//
//  CachingBindTests.swift
//  Exhaust
//

import Exhaust
import Foundation
import Testing

@Suite("bind(caching:)")
struct CachingBindTests {
    @Test("Builds the dependent generator once per distinct value")
    func buildsTheDependentGeneratorOncePerDistinctValue() {
        let counter = ConstructionCounter()
        let generator = #gen(.int(in: 0 ... 3)).bind(caching: { width in
            counter.increment(width)
            return .int(in: 0 ... width)
        })

        #exhaust(#gen(generator), .budget(.custom(screening: 0, sampling: 400))) { value in
            (0 ... 3).contains(value)
        }

        #expect(counter.distinctValues == [0, 1, 2, 3])
        #expect(counter.count == 4)
    }

    @Test("Builds once per distinct value under parallel lanes")
    func buildsOncePerDistinctValueUnderParallelLanes() {
        let counter = ConstructionCounter()
        let generator = #gen(.int(in: 0 ... 3)).bind(caching: { width in
            counter.increment(width)
            return .int(in: 0 ... width)
        })

        #exhaust(#gen(generator), .budget(.custom(screening: 0, sampling: 2000)), .parallelize(lanes: .four)) { value in
            (0 ... 3).contains(value)
        }

        #expect(counter.distinctValues == [0, 1, 2, 3])
        #expect(counter.count == 4)
    }

    @Test("Draws the same values as a plain bind under the same seed")
    func drawsTheSameValuesAsAPlainBindUnderTheSameSeed() {
        func collect(caching: Bool) -> [Int] {
            let recorder = ValueRecorder()
            let widths = #gen(.int(in: 1 ... 5))
            let generator: ReflectiveGenerator<Int> = switch caching {
                case true: widths.bind(caching: { width in .int(in: 0 ... width * 1000) })
                case false: widths.bind { width in .int(in: 0 ... width * 1000) }
            }
            #exhaust(
                #gen(generator),
                .budget(.custom(screening: 0, sampling: 100)),
                .replay(ReplaySeed.numeric(1337))
            ) { value in
                recorder.append(value)
                return true
            }
            return recorder.values
        }

        let cached = collect(caching: true)
        let plain = collect(caching: false)

        #expect(cached.isEmpty == false)
        #expect(cached == plain)
    }

    @Test("Reduction searches through the cached dependent generator")
    func reductionSearchesThroughTheCachedDependentGenerator() {
        let generator = #gen(.int(in: 1 ... 5)).bind(caching: { width in .int(in: 0 ... width * 1000) })
        let reduced = #exhaust(#gen(generator), .suppress(.issueReporting)) { value in
            value < 10
        }

        #expect(reduced == 10)
    }
}

// MARK: - Helpers

private final class ConstructionCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0
    private var seen: Set<Int> = []

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func increment(_ value: Int) {
        lock.lock()
        defer { lock.unlock() }
        storage += 1
        seen.insert(value)
    }

    var distinctValues: [Int] {
        lock.lock()
        defer { lock.unlock() }
        return seen.sorted()
    }
}

private final class ValueRecorder: @unchecked Sendable {
    private(set) var values: [Int] = []

    func append(_ value: Int) {
        values.append(value)
    }
}
