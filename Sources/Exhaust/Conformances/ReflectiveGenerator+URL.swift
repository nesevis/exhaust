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
    /// This generator is forward-only — reflection and shrinking operate on the underlying string components but cannot decompose a URL back into its generator inputs.
    ///
    /// ```swift
    /// let gen = #gen(.url())
    /// ```
    ///
    /// - Returns: A generator producing valid `URL` values.
    static func url() -> ReflectiveGenerator<URL> {
        let scheme: ReflectiveGenerator<String> = Gen.pick(choices: [
            (1, Gen.just("http")),
            (1, Gen.just("https")),
        ])

        let label = alphanumericString(length: 3 ... 10)
        let host = Gen.arrayOf(label, within: 2 ... 3, scaling: .constant)
            ._map { $0.joined(separator: ".") }

        let pathSegment = alphanumericString(length: 1 ... 8)
        let path = Gen.arrayOf(pathSegment, within: 0 ... 3, scaling: .constant)
            ._map { segments in
                segments.isEmpty ? "" : "/" + segments.joined(separator: "/")
            }

        let queryKey = alphanumericString(length: 2 ... 6)
        let queryValue = alphanumericString(length: 1 ... 8)
        let queryPair = Gen.zip(queryKey, queryValue)
            ._map { "\($0)=\($1)" }
        let query = Gen.arrayOf(queryPair, within: 0 ... 2, scaling: .constant)
            ._map { pairs in
                pairs.isEmpty ? "" : "?" + pairs.joined(separator: "&")
            }

        return Gen.zip(scheme, host, path, query)
            .map { scheme, host, path, query in
                URL(string: "\(scheme)://\(host)\(path)\(query)")!
            }
    }
}

// MARK: - Helpers

/// Generates a lowercase alphanumeric string with length in the given range.
private func alphanumericString(
    length: ClosedRange<UInt64>
) -> ReflectiveGenerator<String> {
    let chars = Gen.choose(in: UInt8(0) ... 35)
        ._map { value -> Character in
            if value < 26 {
                Character(UnicodeScalar(UInt8(ascii: "a") + value))
            } else {
                Character(UnicodeScalar(UInt8(ascii: "0") + value - 26))
            }
        }
    return Gen.arrayOf(chars, within: length, scaling: .constant)
        ._map { String($0) }
}
