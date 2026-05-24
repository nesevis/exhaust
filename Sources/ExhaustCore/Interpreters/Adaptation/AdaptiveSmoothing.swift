// Adaptive smoothing for tuned generators.
// Shared between GeneratorTuning (probe-based) and ChoiceGradientTuner (CGS).

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#elseif canImport(Musl)
    import Musl
#endif

/// Namespace for adaptive Laplace smoothing of CGS weight vectors.
package enum AdaptiveSmoothing {
    /// Applies per-site temperature scaling based on entropy analysis.
    ///
    /// Unlike uniform smoothing which applies the same temperature everywhere, this function computes each pick site's entropy ratio and derives a site-specific temperature:
    ///
    /// - Bottleneck sites (low entropy ratio) get high temperature → more exploration
    /// - Well-distributed sites (high entropy ratio) get low temperature → preserve tuned weights
    ///
    /// This avoids sacrificing validity at well-distributed sites while still recovering dead branches at bottleneck sites.
    ///
    /// - Parameters:
    ///   - generator: A tuned generator (typically the output of a tuning pass).
    ///   - epsilon: Laplace smoothing constant. Default: 1.0.
    ///   - baseTemperature: Temperature for well-distributed sites. Default: 1.0.
    ///   - maxTemperature: Temperature for bottleneck sites. Default: 4.0.
    /// - Returns: A generator with adaptively smoothed pick weights.
    public static func smooth<Output>(
        _ generator: Generator<Output>,
        epsilon: Double = 1.0,
        baseTemperature: Double = 1.0,
        maxTemperature: Double = 4.0
    ) -> Generator<Output> {
        smoothGenerator(
            generator,
            epsilon: epsilon,
            baseTemperature: baseTemperature,
            maxTemperature: maxTemperature
        )
    }

    private static func smoothGenerator<Output>(
        _ gen: Generator<Output>,
        epsilon: Double,
        baseTemperature: Double,
        maxTemperature: Double
    ) -> Generator<Output> {
        switch gen {
            case .pure:
                return gen
            case let .impure(operation, continuation):
                let smoothed = smoothOperation(
                    operation,
                    epsilon: epsilon,
                    baseTemperature: baseTemperature,
                    maxTemperature: maxTemperature
                )
                return .impure(operation: smoothed, continuation: continuation)
        }
    }

    private static func smoothOperation(
        _ op: ReflectiveOperation,
        epsilon: Double,
        baseTemperature: Double,
        maxTemperature: Double
    ) -> ReflectiveOperation {
        switch op {
            case let .pick(choices):
                // Compute Shannon entropy to measure how uniform the weight distribution is
                let totalWeight = choices.reduce(into: UInt64(0)) { $0 += $1.weight }
                let entropy: Double
                if totalWeight > 0 {
                    let total = Double(totalWeight)
                    entropy = -choices.reduce(into: 0.0) { sum, choice in
                        let p = Double(choice.weight) / total
                        if p > 0 { sum += p * log2(p) }
                    }
                } else {
                    entropy = log2(Double(choices.count))
                }
                let maxEntropy = log2(Double(choices.count))
                let entropyRatio = maxEntropy > 0 ? entropy / maxEntropy : 1.0

                // Bottleneck sites (low entropy) get high temperature; uniform sites stay cool
                let siteTemp = baseTemperature
                    + (maxTemperature - baseTemperature) * (1.0 - entropyRatio)

                // Apply Laplace smoothing with site-specific temperature: w' = (w + ε)^(1/T)
                let raw = choices.map { pow(Double($0.weight) + epsilon, 1.0 / siteTemp) }
                let rawTotal = raw.reduce(0, +)

                let smoothed = ContiguousArray(choices.enumerated().map { i, choice in
                    ReflectiveOperation.PickTuple(
                        fingerprint: choice.fingerprint,
                        id: choice.id,
                        weight: max(1, UInt64(raw[i] / rawTotal * 10000)),
                        generator: smoothGenerator(
                            choice.generator,
                            epsilon: epsilon,
                            baseTemperature: baseTemperature,
                            maxTemperature: maxTemperature
                        )
                    )
                })

                return .pick(choices: smoothed)

            case let .zip(generators, _):
                return .zip(ContiguousArray(generators.map {
                    smoothGenerator(
                        $0,
                        epsilon: epsilon,
                        baseTemperature: baseTemperature,
                        maxTemperature: maxTemperature
                    )
                }))

            case let .sequence(length, gen):
                let smoothedLength = smoothGenerator(
                    length,
                    epsilon: epsilon,
                    baseTemperature: baseTemperature,
                    maxTemperature: maxTemperature
                )
                let smoothedGen = smoothGenerator(
                    gen,
                    epsilon: epsilon,
                    baseTemperature: baseTemperature,
                    maxTemperature: maxTemperature
                )
                return .sequence(length: smoothedLength, gen: smoothedGen)

            default:
                if let mapped = op.mapInnerGenerator({ smoothGenerator($0, epsilon: epsilon, baseTemperature: baseTemperature, maxTemperature: maxTemperature) }) {
                    return mapped
                }
                return op
        }
    }
}
