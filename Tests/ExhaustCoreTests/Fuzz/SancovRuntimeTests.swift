import ExhaustCore
import Testing

#if canImport(Darwin)
    import Darwin
#endif

/// The registry is process-global, so these tests serialize and reset it around each use. The test binary itself is uninstrumented; no real sancov regions ever register here.
@Suite("SancovRuntime region registry tests", .serialized)
struct SancovRuntimeTests {
    @Test("Uninstrumented process reports no instrumentation")
    func uninstrumented() {
        SancovRuntime.resetForTesting()
        #expect(SancovRuntime.isInstrumented == false)
        #expect(SancovRuntime.edgeCount == 0)
        #expect(SancovCoverageSource() == nil)
    }

    @Test("Regions accumulate across multiple registrations with global offsets")
    func regionAccumulation() {
        SancovRuntime.resetForTesting()
        defer { SancovRuntime.resetForTesting() }

        let first = UnsafeMutablePointer<UInt8>.allocate(capacity: 6)
        let second = UnsafeMutablePointer<UInt8>.allocate(capacity: 4)
        defer {
            first.deallocate()
            second.deallocate()
        }
        first.update(repeating: 0, count: 6)
        second.update(repeating: 0, count: 4)

        SancovRuntime.registerCounters(start: first, end: first + 6)
        SancovRuntime.registerCounters(start: second, end: second + 4)

        #expect(SancovRuntime.isInstrumented)
        #expect(SancovRuntime.edgeCount == 10)
        let regions = SancovRuntime.currentCounterRegions()
        #expect(regions.count == 2)
        #expect(regions[0].globalOffset == 0)
        #expect(regions[1].globalOffset == 6)
    }

    @Test("Re-registration of the same region is idempotent")
    func idempotentRegistration() {
        SancovRuntime.resetForTesting()
        defer { SancovRuntime.resetForTesting() }

        let region = UnsafeMutablePointer<UInt8>.allocate(capacity: 6)
        defer { region.deallocate() }
        region.update(repeating: 0, count: 6)

        SancovRuntime.registerCounters(start: region, end: region + 6)
        SancovRuntime.registerCounters(start: region, end: region + 6)

        #expect(SancovRuntime.edgeCount == 6)
        #expect(SancovRuntime.currentCounterRegions().count == 1)
    }

    @Test("Empty region registration is ignored")
    func emptyRegion() {
        SancovRuntime.resetForTesting()
        defer { SancovRuntime.resetForTesting() }

        let region = UnsafeMutablePointer<UInt8>.allocate(capacity: 1)
        defer { region.deallocate() }
        SancovRuntime.registerCounters(start: region, end: region)
        #expect(SancovRuntime.isInstrumented == false)
    }

    @Test("Source resets counters and reports hit edges with counts under global indexing")
    func sourceResetAndSnapshot() throws {
        SancovRuntime.resetForTesting()
        defer { SancovRuntime.resetForTesting() }

        let first = UnsafeMutablePointer<UInt8>.allocate(capacity: 3)
        let second = UnsafeMutablePointer<UInt8>.allocate(capacity: 3)
        defer {
            first.deallocate()
            second.deallocate()
        }
        first.update(repeating: 7, count: 3)
        second.update(repeating: 7, count: 3)
        SancovRuntime.registerCounters(start: first, end: first + 3)
        SancovRuntime.registerCounters(start: second, end: second + 3)

        let source = try #require(SancovCoverageSource())

        source.beginAttempt()
        var afterReset: [Int] = []
        source.forEachHitEdge { edge, _ in afterReset.append(edge) }
        #expect(afterReset.isEmpty)

        // Simulate the SUT incrementing counters during a property evaluation.
        first[1] = 1
        second[2] = 130

        var hits: [(Int, UInt8)] = []
        source.forEachHitEdge { edge, hitCount in hits.append((edge, hitCount)) }
        #expect(hits.count == 2)
        #expect(hits[0] == (1, 1))
        #expect(hits[1] == (5, 130))

        let signature = source.signature()
        #expect(signature.indices == [1, 5])
        #expect(signature.capacity == 6)
    }

    @Test("PC table resolves global edge indices across regions")
    func pcTableResolution() throws {
        SancovRuntime.resetForTesting()
        defer { SancovRuntime.resetForTesting() }

        // Two counter regions of 2 edges each, with parallel PC tables. Entries are (pc, flags) word pairs; flags bit 0 marks function entries.
        let counters = UnsafeMutablePointer<UInt8>.allocate(capacity: 4)
        defer { counters.deallocate() }
        counters.update(repeating: 0, count: 4)
        SancovRuntime.registerCounters(start: counters, end: counters + 2)
        SancovRuntime.registerCounters(start: counters + 2, end: counters + 4)

        let firstTable = UnsafeMutablePointer<UInt>.allocate(capacity: 4)
        let secondTable = UnsafeMutablePointer<UInt>.allocate(capacity: 4)
        defer {
            firstTable.deallocate()
            secondTable.deallocate()
        }
        firstTable[0] = 0x1000
        firstTable[1] = 1
        firstTable[2] = 0x1010
        firstTable[3] = 0
        secondTable[0] = 0x2000
        secondTable[1] = 1
        secondTable[2] = 0x2010
        secondTable[3] = 0
        SancovRuntime.registerPCTable(start: firstTable, end: firstTable + 4)
        SancovRuntime.registerPCTable(start: secondTable, end: secondTable + 4)

        let entryZero = try #require(SancovRuntime.pcTableEntry(forEdge: 0))
        #expect(entryZero.programCounter == 0x1000)
        #expect(entryZero.isFunctionEntry)

        let entryTwo = try #require(SancovRuntime.pcTableEntry(forEdge: 2))
        #expect(entryTwo.programCounter == 0x2000)

        let entryThree = try #require(SancovRuntime.pcTableEntry(forEdge: 3))
        #expect(entryThree.programCounter == 0x2010)
        #expect(entryThree.isFunctionEntry == false)

        #expect(SancovRuntime.pcTableEntry(forEdge: 4) == nil)
        #expect(SancovRuntime.pcTableEntry(forEdge: -1) == nil)
    }

    #if canImport(Darwin)
        @Test("Symbolisation resolves a PC-table entry pointing at a known symbol")
        func symbolization() throws {
            SancovRuntime.resetForTesting()
            defer { SancovRuntime.resetForTesting() }

            // RTLD_DEFAULT: search every loaded image for a symbol whose address dladdr can then resolve back.
            let handle = UnsafeMutableRawPointer(bitPattern: -2)
            let strlenAddress = try #require(dlsym(handle, "strlen"))

            let table: [UInt] = [UInt(bitPattern: strlenAddress), 1]
            try table.withUnsafeBufferPointer { buffer in
                let base = try #require(buffer.baseAddress)
                SancovRuntime.registerPCTable(
                    start: UnsafeRawPointer(base),
                    end: UnsafeRawPointer(base + 2)
                )
                let descriptions = SancovSymbolizer.symbolize(edges: [0])
                #expect(descriptions[0]?.contains("strlen") == true)
                // An edge with no PC-table entry is omitted, not fabricated.
                #expect(descriptions[7] == nil)
            }
        }
    #endif
}

@Suite("Hit count bucketing tests")
struct HitCountBucketTests {
    @Test("Bucket boundaries match the AFL scheme")
    func bucketBoundaries() {
        #expect(HitCountBucket.bucketIndex(for: 1) == 0)
        #expect(HitCountBucket.bucketIndex(for: 2) == 1)
        #expect(HitCountBucket.bucketIndex(for: 3) == 2)
        #expect(HitCountBucket.bucketIndex(for: 4) == 3)
        #expect(HitCountBucket.bucketIndex(for: 7) == 3)
        #expect(HitCountBucket.bucketIndex(for: 8) == 4)
        #expect(HitCountBucket.bucketIndex(for: 15) == 4)
        #expect(HitCountBucket.bucketIndex(for: 16) == 5)
        #expect(HitCountBucket.bucketIndex(for: 31) == 5)
        #expect(HitCountBucket.bucketIndex(for: 32) == 6)
        #expect(HitCountBucket.bucketIndex(for: 127) == 6)
        #expect(HitCountBucket.bucketIndex(for: 128) == 7)
        #expect(HitCountBucket.bucketIndex(for: 255) == 7)
    }

    @Test("Bucket masks are single distinct bits")
    func bucketMasks() {
        var seen: Set<UInt8> = []
        for hitCount in [1, 2, 3, 4, 8, 16, 32, 128].map({ UInt8($0) }) {
            let mask = HitCountBucket.bucketMask(for: hitCount)
            #expect(mask.nonzeroBitCount == 1)
            seen.insert(mask)
        }
        #expect(seen.count == HitCountBucket.bucketCount)
    }
}
