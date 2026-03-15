//
//  InlineBuffer.swift
//  Exhaust
//

/// Fixed-capacity, stack-allocated buffer backed by an 8-element tuple.
///
/// Replaces small heap-allocated `[T]` arrays on hot paths where the
/// maximum element count is known at design time. Uses `UnsafeRawPointer`
/// internally to index into a homogeneous tuple — same memory layout as
/// a C array, no OS-availability constraints.
struct InlineBuffer<Element> {
    private var storage: (Element, Element, Element, Element,
                          Element, Element, Element, Element)
    private(set) var count: Int

    static var capacity: Int { 8 }

    init(repeating value: Element) {
        storage = (value, value, value, value, value, value, value, value)
        count = 0
    }

    subscript(index: Int) -> Element {
        get {
            assert(index >= 0 && index < count, "InlineBuffer index out of range")
            return withUnsafePointer(to: storage) {
                UnsafeRawPointer($0)
                    .assumingMemoryBound(to: Element.self)
                    .advanced(by: index)
                    .pointee
            }
        }
        set {
            assert(index >= 0 && index < Self.capacity, "InlineBuffer index out of range")
            withUnsafeMutablePointer(to: &storage) {
                UnsafeMutableRawPointer($0)
                    .assumingMemoryBound(to: Element.self)
                    .advanced(by: index)
                    .pointee = newValue
            }
        }
    }

    mutating func append(_ value: Element) {
        assert(count < Self.capacity, "InlineBuffer overflow")
        self[count] = value
        count &+= 1
    }

    @discardableResult
    mutating func removeLast() -> Element {
        let value = self[count &- 1]
        count &-= 1
        return value
    }

    mutating func popLast() -> Element? {
        guard isEmpty == false else { return nil }
        return removeLast()
    }

    var last: Element? {
        guard isEmpty == false else { return nil }
        return self[count &- 1]
    }

    var isEmpty: Bool { count == 0 } // swiftlint:disable:this empty_count
}
