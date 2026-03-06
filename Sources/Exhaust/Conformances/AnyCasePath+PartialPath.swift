#if CasePathable
import CasePaths
import ExhaustCore

extension AnyCasePath: PartialPath {
    public func extract(from root: Any) throws -> Value? {
        guard let root = root as? Root else { return nil }
        return extract(from: root)
    }
}
#endif
