/// Rejects terminal work only when a fixed value prefix already prevents improvement. Structural entries cannot decide before the full value projection is compared.
enum BoundValueTerminalOrder {
    /// Keeps terminal rejections in the probe budget when nested controllers remain fixed; pruning them can spend more lifts before the dispatch cap is reached.
    static func rejectsTerminal(_ lifted: LiftedBind, incumbent: ChoiceSequence) -> Bool {
        lifted.graph.canComposeAllNestedBinds(under: lifted.bindNodeID)
            && canImprove(lifted.sequence, fixedBefore: lifted.boundRange.lowerBound, incumbent: incumbent) == false
    }

    /// Compares the fixed value projection without ruling out improvements in the remaining suffix.
    static func canImprove(_ candidate: ChoiceSequence, fixedBefore prefixEnd: Int, incumbent: ChoiceSequence) -> Bool {
        if candidate.count != incumbent.count {
            return candidate.count < incumbent.count
        }
        var incumbentIndex = 0
        for index in 0 ..< min(prefixEnd, candidate.count) {
            guard let value = candidate[index].value else {
                continue
            }
            while incumbentIndex < incumbent.count, incumbent[incumbentIndex].value == nil {
                incumbentIndex += 1
            }
            guard let incumbentValue = incumbentIndex < incumbent.count ? incumbent[incumbentIndex].value : nil else {
                return false
            }
            switch value.shortLexCompare(incumbentValue) {
                case .lt:
                    return true
                case .gt:
                    return false
                case .eq:
                    incumbentIndex += 1
            }
        }
        return true
    }
}
