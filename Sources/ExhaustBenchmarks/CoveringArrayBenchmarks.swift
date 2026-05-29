import Benchmark
import ExhaustCore

func registerCoveringArrayBenchmarks() {
    let threeParamDomains: [UInt64] = [48, 48, 55]
    let fiveParamDomains: [UInt64] = [48, 48, 55, 5, 3]

    // MARK: - 3 parameters, standard budget (200 rows)

    benchmark("CoveringArray: PBCAG 3-param 200 rows") {
        let generator = PullBasedCoveringArrayGenerator(
            domainSizes: threeParamDomains,
            strength: 2
        )
        for _ in 0 ..< 200 {
            _ = generator.next()
        }
    }

    benchmark("CoveringArray: BCAG 3-param 200 rows") {
        let generator = BalancedCoveringArrayGenerator(domainSizes: threeParamDomains)
        for _ in 0 ..< 200 {
            _ = generator.next()
        }
    }

    // MARK: - 5 parameters, standard budget (200 rows)

    benchmark("CoveringArray: PBCAG 5-param 200 rows") {
        let generator = PullBasedCoveringArrayGenerator(
            domainSizes: fiveParamDomains,
            strength: 2
        )
        for _ in 0 ..< 200 {
            _ = generator.next()
        }
    }

    benchmark("CoveringArray: BCAG 5-param 200 rows") {
        let generator = BalancedCoveringArrayGenerator(domainSizes: fiveParamDomains)
        for _ in 0 ..< 200 {
            _ = generator.next()
        }
    }

    // MARK: - 3 parameters, extensive budget (2000 rows)

    benchmark("CoveringArray: PBCAG 3-param 2000 rows") {
        let generator = PullBasedCoveringArrayGenerator(
            domainSizes: threeParamDomains,
            strength: 2
        )
        for _ in 0 ..< 2000 {
            _ = generator.next()
        }
    }

    benchmark("CoveringArray: BCAG 3-param 2000 rows") {
        let generator = BalancedCoveringArrayGenerator(domainSizes: threeParamDomains)
        for _ in 0 ..< 2000 {
            _ = generator.next()
        }
    }
}
