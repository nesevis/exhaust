//
//  FiniteDomainAnalysis.swift
//  Exhaust
//

/// A single factor in the combinatorial model.
@_spi(ExhaustInternal) public struct FiniteParameter: @unchecked Sendable {
    /// The type of generator operation this parameter came from.
    @_spi(ExhaustInternal) public enum Kind {
        case chooseBits(range: ClosedRange<UInt64>, tag: TypeTag)
        case pick(choices: ContiguousArray<ReflectiveOperation.PickTuple>)
    }

    @_spi(ExhaustInternal) public let index: Int
    @_spi(ExhaustInternal) public let domainSize: UInt64
    @_spi(ExhaustInternal) public let kind: Kind
}

/// Result of analyzing a generator for finite-domain structure.
@_spi(ExhaustInternal) public struct FiniteDomainProfile: @unchecked Sendable {
    @_spi(ExhaustInternal) public let parameters: [FiniteParameter]
    /// Product of all domainSizes. Capped at UInt64.max on overflow.
    @_spi(ExhaustInternal) public let totalSpace: UInt64
}

/// Walks a `ReflectiveGenerator` tree to detect purely-finite generators
/// and extract parameter domains for covering array construction.
///
/// This analysis enables t-way combinatorial testing as described by
/// Lei & Kacker in "IPOG: A General Strategy for T-Way Software Testing"
/// (ECBS 2007). The extracted ``FiniteDomainProfile`` maps directly to the
/// *parameter model* that IPOG requires as input: each ``FiniteParameter``
/// corresponds to a factor with a known domain size.
@_spi(ExhaustInternal) public enum FiniteDomainAnalysis {

    /// Maximum domain size for a single parameter to be considered finite.
    private static let maxDomainSize: UInt64 = 256

    /// Analyzes a generator and returns a profile if it is entirely finite-domain.
    /// Returns `nil` if any parameter is non-finite or the structure is too complex.
    public static func analyze<Output>(_ gen: ReflectiveGenerator<Output>) -> FiniteDomainProfile? {
        var parameters: [FiniteParameter] = []
        guard analyzeRecursive(gen.erase(), parameters: &parameters) else {
            return nil
        }
        guard parameters.isEmpty == false else {
            return nil // No randomness at all (pure generator)
        }

        var totalSpace: UInt64 = 1
        for param in parameters {
            let (product, overflow) = totalSpace.multipliedReportingOverflow(by: param.domainSize)
            if overflow {
                totalSpace = .max
                break
            }
            totalSpace = product
        }

        return FiniteDomainProfile(parameters: parameters, totalSpace: totalSpace)
    }

    // MARK: - Recursive Walk

    private static func analyzeRecursive(
        _ gen: ReflectiveGenerator<Any>,
        parameters: inout [FiniteParameter],
    ) -> Bool {
        switch gen {
        case .pure:
            return true

        case let .impure(operation, continuation):
            return analyzeOperation(operation, continuation: continuation, parameters: &parameters)
        }
    }

    private static func analyzeOperation(
        _ operation: ReflectiveOperation,
        continuation: @escaping (Any) throws -> ReflectiveGenerator<Any>,
        parameters: inout [FiniteParameter],
    ) -> Bool {
        switch operation {
        case let .chooseBits(min, max, tag, isRangeExplicit):
            guard isRangeExplicit else { return false }
            let domainSize = max - min + 1
            guard domainSize <= maxDomainSize else { return false }

            let param = FiniteParameter(
                index: parameters.count,
                domainSize: domainSize,
                kind: .chooseBits(range: min ... max, tag: tag)
            )
            parameters.append(param)

            // Probe the continuation with the minimum value to check for further choices
            guard let nextGen = try? continuation(tag.makeConvertible(bitPattern64: min)) else {
                return false
            }
            return analyzeContinuation(nextGen)

        case let .pick(choices):
            guard choices.isEmpty == false else { return false }
            let domainSize = UInt64(choices.count)
            guard domainSize <= maxDomainSize else { return false }

            // Check that every branch's sub-generator has zero additional parameters
            for choice in choices {
                var branchParams: [FiniteParameter] = []
                guard analyzeRecursive(choice.generator, parameters: &branchParams) else {
                    return false
                }
                guard branchParams.isEmpty else {
                    return false // Branch has sub-generators with their own randomness
                }
            }

            let param = FiniteParameter(
                index: parameters.count,
                domainSize: domainSize,
                kind: .pick(choices: choices)
            )
            parameters.append(param)

            // Probe the continuation with the first branch's result
            let firstGen = choices[0].generator
            guard case let .pure(value) = firstGen else {
                return false
            }
            guard let nextGen = try? continuation(value) else {
                return false
            }
            return analyzeContinuation(nextGen)

        case let .zip(generators):
            for generator in generators {
                guard analyzeRecursive(generator, parameters: &parameters) else {
                    return false
                }
            }
            // Zip's continuation converts [Any] → tuple. We can't safely probe it
            // without real typed values. Since zip is always terminal in #gen macro
            // expansions, we trust that no further bind-chains follow.
            return true

        case let .contramap(_, next):
            return analyzeRecursive(next, parameters: &parameters)

        case let .prune(next):
            return analyzeRecursive(next, parameters: &parameters)

        case .just:
            // Pure value, no parameters — probe continuation
            guard let nextGen = try? continuation(operation.justValue!) else {
                return false
            }
            return analyzeContinuation(nextGen)

        case let .classify(gen, _, _):
            return analyzeRecursive(gen, parameters: &parameters)

        // Non-finite operations
        case .sequence, .getSize, .resize, .filter, .unique:
            return false
        }
    }

    /// Checks that the continuation produces no further random choices.
    private static func analyzeContinuation(_ gen: ReflectiveGenerator<Any>) -> Bool {
        switch gen {
        case .pure:
            return true
        case .impure:
            // Bind-chain: further random choices follow — not supported yet
            return false
        }
    }
}

// MARK: - Helpers

private extension ReflectiveOperation {
    var justValue: Any? {
        if case let .just(value) = self {
            return value
        }
        return nil
    }
}
