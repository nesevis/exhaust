import Exhaust

// MARK: - Bound5 Type

struct Bound5: Equatable, CustomStringConvertible {
    let a: [Int16]
    let b: [Int16]
    let c: [Int16]
    let d: [Int16]
    let e: [Int16]
    let arr: [Int16]

    init(a: [Int16], b: [Int16], c: [Int16], d: [Int16], e: [Int16]) {
        self.a = a
        self.b = b
        self.c = c
        self.d = d
        self.e = e
        arr = a + b + c + d + e
    }

    var description: String {
        "Bound5(a: \(a), b: \(b), c: \(c), d: \(d), e: \(e))"
    }
}

// MARK: - Generator

let bound5Gen = {
    let arrayGen = #gen(.int16(scaling: .constant).array(length: 0 ... 10, scaling: .constant))
        .filter { $0.isEmpty || $0.dropFirst().reduce($0[0], &+) < 256 }
    return #gen(arrayGen, arrayGen, arrayGen, arrayGen, arrayGen) { a, b, c, d, e in
        Bound5(a: a, b: b, c: c, d: d, e: e)
    }
}()

// MARK: - Property

let bound5Property: @Sendable (Bound5) -> Bool = { bound5 in
    if bound5.arr.isEmpty { return true }
    return bound5.arr.dropFirst().reduce(bound5.arr[0], &+) < 5 * 256
}
