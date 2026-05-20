import Exhaust
import Testing

// MARK: - Generator Sharing Across Concurrent Tasks

@Suite("Concurrency safety — generator sharing")
struct GeneratorSharingTests {
    @Test("Shared generator interpreted concurrently via #example")
    func sharedGeneratorConcurrentExample() async {
        let gen = #gen(.int(in: 0 ... 10_000).array(length: 5 ... 15))

        await withTaskGroup(of: [Int].self) { group in
            for seed in 0 as UInt64 ..< 20 {
                group.addTask {
                    #example(gen, seed: seed)
                }
            }
            for await values in group {
                #expect(values.count >= 5 && values.count <= 15)
                for value in values {
                    #expect((0 ... 10_000).contains(value))
                }
            }
        }
    }

    @Test("Shared composed generator with mapped/bound closures interpreted concurrently")
    func sharedComposedGeneratorConcurrent() async {
        let gen = #gen(.int(in: 1 ... 100))
            .mapped(forward: { "\($0)" }, backward: { Int($0) ?? 0 })
            .array(length: 3 ... 10)

        await withTaskGroup(of: [[String]].self) { group in
            for seed in 0 as UInt64 ..< 20 {
                group.addTask {
                    #example(gen, count: 10, seed: seed)
                }
            }
            for await batches in group {
                #expect(batches.count == 10)
                for batch in batches {
                    #expect(batch.count >= 3 && batch.count <= 10)
                }
            }
        }
    }

    @Test("Shared generator with filter interpreted concurrently")
    func sharedFilteredGeneratorConcurrent() async {
        let gen = #gen(.int(in: 0 ... 1000)).filter { $0 % 2 == 0 }.array(length: 5)

        await withTaskGroup(of: [[Int]].self) { group in
            for seed in 0 as UInt64 ..< 20 {
                group.addTask {
                    #example(gen, count: 5, seed: seed)
                }
            }
            for await batches in group {
                for batch in batches {
                    #expect(batch.count == 5)
                    for value in batch {
                        #expect(value % 2 == 0)
                    }
                }
            }
        }
    }

    @Test("Shared oneOf generator with @Sendable closures interpreted concurrently")
    func sharedOneOfGeneratorConcurrent() async {
        let gen = #gen(.oneOf(
            .int(in: 0 ... 100).mapped(forward: { "\($0)" }, backward: { Int($0) ?? 0 }),
            .string(length: 1 ... 5)
        )).array(length: 10)

        await withTaskGroup(of: [[String]].self) { group in
            for seed in 0 as UInt64 ..< 20 {
                group.addTask {
                    #example(gen, count: 5, seed: seed)
                }
            }
            for await batches in group {
                for batch in batches {
                    #expect(batch.count == 10)
                }
            }
        }
    }

    @Test("Shared recursive generator interpreted concurrently")
    func sharedRecursiveGeneratorConcurrent() async {
        let gen = ReflectiveGenerator<[Any]>.recursive(
            base: #gen(.int(in: 0 ... 10)).mapped(
                forward: { [$0 as Any] },
                backward: { ($0.first as? Int) ?? 0 }
            ),
            depthRange: 0 ... 3,
            extend: { recurse, _ in
                #gen(recurse(), recurse()) { left, right in
                    [left as Any, right as Any]
                }
            }
        )

        await withTaskGroup(of: Void.self) { group in
            for seed in 0 as UInt64 ..< 20 {
                group.addTask {
                    let values = #example(gen, count: 10, seed: seed)
                    #expect(values.count == 10)
                }
            }
        }
    }

    @Test("Shared bound generator interpreted concurrently")
    func sharedBoundGeneratorConcurrent() async {
        let gen = #gen(.int(in: 1 ... 10)).bound(
            forward: { length in .string(length: 1...length) },
            backward: \.count
        )

        await withTaskGroup(of: [String].self) { group in
            for seed in 0 as UInt64 ..< 20 {
                group.addTask {
                    #example(gen, count: 10, seed: seed)
                }
            }
            for await batch in group {
                #expect(batch.count == 10)
                for value in batch {
                    #expect((1 ... 10).contains(value.count))
                }
            }
        }
    }
}

// MARK: - Concurrent #exhaust Invocations

@Suite("Concurrency safety — concurrent #exhaust")
struct ConcurrentExhaustTests {
    @Test("Same generator used in concurrent #exhaust calls")
    func concurrentExhaustCalls() async {
        let gen = #gen(.int(in: 0 ... 100))

        await withTaskGroup(of: Int?.self) { group in
            for _ in 0 ..< 10 {
                group.addTask {
                    #exhaust(gen, .budget(.quick), .suppress(.all)) { value in
                        value < 50
                    }
                }
            }
            for await result in group {
                if let counterexample = result {
                    #expect(counterexample >= 50)
                }
            }
        }
    }

    @Test("Composed generator with closures used in concurrent #exhaust calls")
    func concurrentExhaustWithClosures() async {
        let gen = #gen(.int(in: 0 ... 1000))
            .mapped(forward: { $0 * 2 }, backward: { $0 / 2 })
            .filter { $0 < 1500 }

        await withTaskGroup(of: Int?.self) { group in
            for _ in 0 ..< 10 {
                group.addTask {
                    #exhaust(gen, .budget(.quick), .suppress(.all)) { value in
                        value < 1000
                    }
                }
            }
            for await result in group {
                if let counterexample = result {
                    #expect(counterexample >= 1000)
                }
            }
        }
    }
}

// MARK: - Async Property Bridge (SendableBox)

@Suite("Concurrency safety — async property bridge")
struct AsyncPropertyBridgeTests {
    @Test("Async property with suspension point under concurrent exhaust")
    func asyncPropertyWithSuspension() async {
        let gen = #gen(.int(in: 0 ... 100))

        await withTaskGroup(of: Int?.self) { group in
            for _ in 0 ..< 10 {
                group.addTask {
                    await #exhaust(gen, .budget(.quick), .suppress(.all)) { value async in
                        await Task.yield()
                        return value < 50
                    }
                }
            }
            for await result in group {
                if let counterexample = result {
                    #expect(counterexample >= 50)
                }
            }
        }
    }

    @Test("Async Void/#expect property with suspension point under concurrent exhaust")
    func asyncExpectWithSuspension() async {
        let gen = #gen(.int(in: 0 ... 100))

        await withTaskGroup(of: Int?.self) { group in
            for _ in 0 ..< 5 {
                group.addTask {
                    await #exhaust(gen, .budget(.quick), .suppress(.all)) { value async in
                        await Task.yield()
                        #expect(value < 50)
                    }
                }
            }
            for await result in group {
                if let counterexample = result {
                    #expect(counterexample >= 50)
                }
            }
        }
    }
}

// MARK: - Concurrent Contract Testing (Drain Loop + Foreign Executor)

@Suite("Concurrency safety — concurrent contract drain loop")
struct ConcurrentContractDrainLoopTests {
    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test("Concurrent contract with Task.yield suspension points")
    func contractWithYieldSuspensions() async throws {
        let result = try #require(
            await __runContractConcurrent(
                YieldingCounterSpec.self,
                settings: [
                    .commandLimit(6),
                    .budget(.custom(coverage: 0, sampling: 100)),
                    .suppress(.issueReporting)
                ]
            )
        )
        #expect(result.commands.count >= 2)
    }

    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test("Multiple concurrent contract runs in parallel")
    func parallelContractRuns() async {
        await withTaskGroup(of: Void.self) { group in
            for _ in 0 ..< 5 {
                group.addTask {
                    _ = await __runContractConcurrent(
                        YieldingCounterSpec.self,
                        settings: [
                            .commandLimit(4),
                            .budget(.custom(coverage: 0, sampling: 50)),
                            .suppress(.all)
                        ]
                    )
                }
            }
        }
    }

    @available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
    @Test("Concurrent contract with bundle draws across lanes")
    func contractWithBundleAcrossLanes() async {
        _ = await __runContractConcurrent(
            BundleDrawSpec.self,
            settings: [
                .commandLimit(8),
                .concurrency(3),
                .budget(.custom(coverage: 0, sampling: 100)),
                .suppress(.all)
            ]
        )
    }
}

// MARK: - Specs

@available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
@Contract
final class YieldingCounterSpec {
    @Model var expected: Int = 0
    @SystemUnderTest var counter: YieldingCounter = .init()

    @Invariant
    func matchesModel() -> Bool {
        counter.value == expected
    }

    @Command(weight: 3)
    func increment() async {
        expected += 1
        await counter.increment()
    }

    @Command(weight: 2)
    func decrement() async throws {
        guard expected > 0 else { throw skip() }
        expected -= 1
        await counter.decrement()
    }
}

@available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
@Contract
final class BundleDrawSpec {
    let tokens = Bundle<Int>()
    @Model var model: [Int] = []
    @SystemUnderTest var store: TokenStore = .init()

    @Invariant
    func countMatches() -> Bool {
        store.count == model.count
    }

    @Command(weight: 3, #gen(.int(in: 0 ... 100)))
    func deposit(value: Int) async {
        model.append(value)
        await store.deposit(value)
        tokens.add(value)
    }

    @Command(weight: 2)
    func withdraw() async throws {
        guard let token = tokens.draw(at: 0) else { throw skip() }
        guard let index = model.firstIndex(of: token) else { throw skip() }
        model.remove(at: index)
        await store.withdraw(token)
    }
}

// MARK: - SUTs

@available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
final class YieldingCounter: @unchecked Sendable {
    private var _value: Int = 0

    var value: Int { _value }

    func increment() async {
        let current = _value
        await Task.yield()
        _value = current + 1
    }

    func decrement() async {
        let current = _value
        await Task.yield()
        _value = current - 1
    }
}

@available(macOS 15, iOS 18, tvOS 18, watchOS 11, visionOS 2, *)
final class TokenStore: @unchecked Sendable {
    private var _items: [Int] = []

    var count: Int { _items.count }

    func deposit(_ value: Int) async {
        await Task.yield()
        _items.append(value)
    }

    func withdraw(_ value: Int) async {
        await Task.yield()
        if let index = _items.firstIndex(of: value) {
            _items.remove(at: index)
        }
    }
}
