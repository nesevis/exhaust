//
//  ExhaustIterator.swift
//  Exhaust
//

/// A `~Copyable`-compatible replacement for `IteratorProtocol`.
///
/// Standard `IteratorProtocol` requires `Copyable`, which prevents types
/// containing `~Copyable` fields (like `Xoshiro256`) from conforming.
public protocol ExhaustIterator<Element>: ~Copyable {
    associatedtype Element
    mutating func next() -> Element?
}

extension ExhaustIterator where Self: ~Copyable {
    /// Return the first `n` elements as an array.
    public mutating func prefix(_ n: Int) -> [Element] {
        var result = [Element]()
        result.reserveCapacity(n)
        for _ in 0 ..< n {
            guard let element = next() else { break }
            result.append(element)
        }
        return result
    }
}

extension Array {
    /// Collect all elements from a `~Copyable` iterator.
    public init(collecting iterator: inout some ExhaustIterator<Element> & ~Copyable) {
        self = []
        while let element = iterator.next() {
            append(element)
        }
    }
}
