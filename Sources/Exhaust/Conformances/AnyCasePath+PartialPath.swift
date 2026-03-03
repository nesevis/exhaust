#if CasePathable
import CasePaths
@_spi(ExhaustInternal) import ExhaustCore

extension AnyCasePath: PartialPath {
    public func extract(from root: Any) throws -> Value? {
        guard let root = root as? Root else { return nil }
        return extract(from: root)
    }
}
#endif
