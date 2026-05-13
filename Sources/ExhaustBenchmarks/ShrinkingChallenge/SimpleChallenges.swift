import Exhaust

// MARK: - Coupling

let couplingGen = #refGen(.int(in: 0 ... 10))
    .bind { n in
        #refGen(.int(in: 0 ... n)).array(length: 2 ... max(2, n + 1))
    }
    .filter { arr in arr.allSatisfy { arr.indices.contains($0) } }

let couplingProperty: @Sendable ([Int]) -> Bool = { arr in
    arr.indices.allSatisfy { i in
        let j = arr[i]
        if j != i, arr[j] == i {
            return false
        }
        return true
    }
}

// MARK: - Deletion

let deletionGen = {
    let numberGen = #refGen(.int(in: 0 ... 20))
    return #refGen(numberGen.array(length: 2 ... 20), numberGen)
        .filter { $0.contains($1) }
}()

let deletionProperty: @Sendable (([Int], Int)) -> Bool = { pair in
    var array = pair.0
    let element = pair.1
    guard let index = array.firstIndex(of: element) else { return true }
    array.remove(at: index)
    return array.contains(element) == false
}

// MARK: - Difference (Must Not Be Zero)

let differenceMustNotBeZeroGen = #refGen(.int(in: 1 ... 1000)).array(length: 2)

let differenceMustNotBeZeroProperty: @Sendable ([Int]) -> Bool = { arr in
    arr[0] < 10 || arr[0] != arr[1]
}

// MARK: - Difference (Must Not Be Small)

let differenceMustNotBeSmallGen = #refGen(.int(in: 1 ... 1000)).array(length: 2)

let differenceMustNotBeSmallProperty: @Sendable ([Int]) -> Bool = { arr in
    let diff = abs(arr[0] - arr[1])
    return arr[0] < 10 || diff < 1 || diff > 4
}

// MARK: - Difference (Must Not Be One)

let differenceMustNotBeOneGen = #refGen(.int(in: 1 ... 1000)).array(length: 2)

let differenceMustNotBeOneProperty: @Sendable ([Int]) -> Bool = { arr in
    let diff = abs(arr[0] - arr[1])
    return arr[0] < 10 || diff != 1
}

// MARK: - Distinct

let distinctGen = #refGen(.int().array(length: 3 ... 30))

let distinctProperty: @Sendable ([Int]) -> Bool = { arr in
    Set(arr).count < 3
}

// MARK: - Large Union List

let largeUnionListGen = #refGen(.int().array(length: 1 ... 10).array(length: 1 ... 10))

let largeUnionListProperty: @Sendable ([[Int]]) -> Bool = { arr in
    Set(arr.flatMap(\.self)).count <= 4
}

// MARK: - Length List

let lengthListGen = #refGen(.uint(in: 0 ... 1000)).array(length: 1 ... 100)

let lengthListProperty: @Sendable ([UInt]) -> Bool = { arr in
    arr.max() ?? 0 < 900
}

// MARK: - Nested Lists

let nestedListsGen = #refGen(.uint().array().array())

let nestedListsProperty: @Sendable ([[UInt]]) -> Bool = { arrs in
    var count = 0
    for arr in arrs {
        count += arr.count
        if count > 10 {
            return false
        }
    }
    return count <= 10
}

// MARK: - Replacement

func replacementProds(_ initial: Int, _ multipliers: [Int]) -> [Int] {
    var result = [initial]
    var running = initial
    for multiplier in multipliers {
        let (product, overflow) = running.multipliedReportingOverflow(by: multiplier)
        running = overflow ? Int.max : product
        result.append(running)
    }
    return result
}

let replacementGen = #refGen(.int(in: 0 ... 1_000_000), .int(in: 2 ... 10).array())

let replacementProperty: @Sendable ((Int, [Int])) -> Bool = { pair in
    let (initial, multipliers) = pair
    return replacementProds(initial, multipliers).allSatisfy { $0 < 1_000_000 }
}

// MARK: - Reverse

let reverseGen = #refGen(.uint()).array(length: 1 ... 1000)

let reverseProperty: @Sendable ([UInt]) -> Bool = { arr in
    arr.elementsEqual(arr.reversed())
}
