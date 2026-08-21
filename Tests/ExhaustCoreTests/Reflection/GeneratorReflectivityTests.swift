//
//  GeneratorReflectivityTests.swift
//  ExhaustTests
//
//  Core-level checks that the `isReflective` flag is carried at construction and lost monotonically.
//  The public-factory and macro propagation cases live in ExhaustTests' GeneratorReflectivityPropagationTests.
//

import ExhaustCore
import Testing

@Suite("Generator Reflectivity")
struct GeneratorReflectivityTests {
    @Test("A leaf generator is reflective")
    func leafIsReflective() {
        let gen = Gen.choose(in: 0 ... 100).wrapped(isReflective: true)
        #expect(gen.isReflective)
    }

    @Test("A forward-only map breaks reflectivity")
    func mapBreaksReflectivity() {
        let gen = Gen.choose(in: 0 ... 100).wrapped(isReflective: true).map { $0 * 2 }
        #expect(gen.isReflective == false)
    }

    @Test("A bidirectional mapped preserves reflectivity")
    func mappedPreservesReflectivity() {
        let gen = Gen.choose(in: 0 ... 100).wrapped(isReflective: true).mapped(forward: { $0 * 2 }, backward: { $0 / 2 })
        #expect(gen.isReflective)
    }

    @Test("Reflectivity is monotone: once a forward-only map breaks it, later composition stays false")
    func reflectivityIsMonotone() {
        let gen = Gen.choose(in: 0 ... 100).wrapped(isReflective: true)
            .map { $0 * 2 }
            .mapped(forward: { $0 + 1 }, backward: { $0 - 1 })
        #expect(gen.isReflective == false)
    }

    @Test("oneOf is reflective only when every branch is")
    func oneOfPropagatesBranchFlags() {
        let reflective = Gen.choose(in: 0 ... 100).wrapped(isReflective: true)
        let broken = reflective.map(\.self)
        let mixed: ReflectiveGenerator<Int> = .oneOf(reflective, broken)
        let uniform: ReflectiveGenerator<Int> = .oneOf(reflective, reflective)
        #expect(mixed.isReflective == false)
        #expect(uniform.isReflective)
    }

    @Test("optional propagates its inner generator's reflectivity")
    func optionalPropagatesInnerFlag() {
        let reflective = Gen.choose(in: 0 ... 100).wrapped(isReflective: true)
        let broken = reflective.map(\.self)
        #expect(reflective.optional().isReflective)
        #expect(broken.optional().isReflective == false)
    }
}
