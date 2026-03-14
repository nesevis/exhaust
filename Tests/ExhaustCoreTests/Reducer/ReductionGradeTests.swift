import Testing
import ExhaustCore

@Suite("ApproximationClass")
struct ApproximationClassTests {
    @Test("Lattice join is associative")
    func associativity() {
        let cases: [ApproximationClass] = [.exact, .bounded, .speculative]
        for a in cases {
            for b in cases {
                for c in cases {
                    let lhs = a.composed(with: b).composed(with: c)
                    let rhs = a.composed(with: b.composed(with: c))
                    #expect(lhs == rhs, "(\(a) ⊗ \(b)) ⊗ \(c) != \(a) ⊗ (\(b) ⊗ \(c))")
                }
            }
        }
    }

    @Test("Exact is the lattice join identity")
    func identity() {
        let cases: [ApproximationClass] = [.exact, .bounded, .speculative]
        for a in cases {
            #expect(a.composed(with: .exact) == a)
            #expect(ApproximationClass.exact.composed(with: a) == a)
        }
    }

    @Test("Lattice join is commutative")
    func commutativity() {
        let cases: [ApproximationClass] = [.exact, .bounded, .speculative]
        for a in cases {
            for b in cases {
                #expect(a.composed(with: b) == b.composed(with: a))
            }
        }
    }

    @Test("Lattice join is idempotent")
    func idempotency() {
        let cases: [ApproximationClass] = [.exact, .bounded, .speculative]
        for a in cases {
            #expect(a.composed(with: a) == a)
        }
    }

    @Test("Ordering: exact < bounded < speculative")
    func ordering() {
        #expect(ApproximationClass.exact < .bounded)
        #expect(ApproximationClass.bounded < .speculative)
        #expect(ApproximationClass.exact < .speculative)
    }
}

@Suite("ReductionGrade")
struct ReductionGradeTests {
    @Test("Resource additivity under composition")
    func resourceAdditivity() {
        let a = ReductionGrade(approximation: .exact, maxMaterializations: 5)
        let b = ReductionGrade(approximation: .bounded, maxMaterializations: 10)
        let composed = a.composed(with: b)
        #expect(composed.maxMaterializations == 15)
    }

    @Test("Approximation under composition is lattice join")
    func approximationComposition() {
        let a = ReductionGrade(approximation: .exact, maxMaterializations: 5)
        let b = ReductionGrade(approximation: .bounded, maxMaterializations: 10)
        #expect(a.composed(with: b).approximation == .bounded)

        let c = ReductionGrade(approximation: .speculative, maxMaterializations: 1)
        #expect(a.composed(with: c).approximation == .speculative)
        #expect(b.composed(with: c).approximation == .speculative)
    }

    @Test("Exact identity preserves grade")
    func exactIdentity() {
        let g = ReductionGrade(approximation: .bounded, maxMaterializations: 7)
        let composed = g.composed(with: .exact)
        #expect(composed.approximation == .bounded)
        #expect(composed.maxMaterializations == 7)
    }

    @Test("isExact")
    func isExact() {
        #expect(ReductionGrade.exact.isExact)
        #expect(ReductionGrade(approximation: .exact, maxMaterializations: 5).isExact)
        #expect(ReductionGrade(approximation: .bounded, maxMaterializations: 0).isExact == false)
    }

    @Test("composed(withDecoder:) consistent with composed(with:)")
    func composedWithDecoder() {
        let encoder = ReductionGrade(approximation: .exact, maxMaterializations: 10)
        let decoderClass = ApproximationClass.bounded
        let viaDecoder = encoder.composed(withDecoder: decoderClass)
        let viaGrade = encoder.composed(with: ReductionGrade(approximation: decoderClass, maxMaterializations: 0))
        #expect(viaDecoder.approximation == viaGrade.approximation)
        #expect(viaDecoder.maxMaterializations == viaGrade.maxMaterializations)
    }
}
