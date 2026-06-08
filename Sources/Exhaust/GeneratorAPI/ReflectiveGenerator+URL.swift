//
//  ReflectiveGenerator+URL.swift
//  Exhaust
//

import ExhaustCore
import Foundation

public extension ReflectiveGenerator {
    /// Generates arbitrary URL values with randomized structure.
    ///
    /// Produces URLs with a random scheme (`http` or `https`), host (two to three labels of three to ten lowercase alphanumeric characters), zero to three path segments, and zero to two query parameters. All generated strings are valid URL components, so the resulting URL always parses successfully.
    ///
    /// This generator is forward-only — reflection cannot decompose a URL back into its generator inputs. Reduction still simplifies counterexamples via the underlying choice sequence.
    ///
    /// ```swift
    /// let gen = #gen(.url())
    /// ```
    ///
    /// - Returns: A generator producing valid `URL` values.
    static func url() -> ReflectiveGenerator<URL> {
        Gen.url()
    }
}
