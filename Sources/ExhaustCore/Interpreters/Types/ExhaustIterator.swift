//
//  ExhaustIterator.swift
//  Exhaust
//

/// A `~Copyable`-compatible replacement for `IteratorProtocol`.
///
/// Standard `IteratorProtocol` requires `Copyable`, which prevents types containing `~Copyable` fields (like `Xoshiro256`) from conforming.
public protocol ExhaustIterator<Element>: ~Copyable {
    associatedtype Element
    mutating func next() throws -> Element?
}

public extension ExhaustIterator where Self: ~Copyable {
    /// Return the first `n` elements as an array.
    mutating func prefix(_ n: Int) throws -> [Element] {
        var result = [Element]()
        result.reserveCapacity(n)
        for _ in 0 ..< n {
            guard let element = try next() else { break }
            result.append(element)
        }
        return result
    }
}

public extension Array {
    /// Collect all elements from a `~Copyable` iterator.
    init(collecting iterator: inout some ExhaustIterator<Element> & ~Copyable) throws {
        self = []
        while let element = try iterator.next() {
            append(element)
        }
    }
}
