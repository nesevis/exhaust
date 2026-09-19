import ExhaustTestSupport
import Testing

@Suite("anyEquals")
struct AnyEqualsTests {
    @Test("anyEquals correctly compares optional values")
    func optionalEquality() {
        #expect(anyEquals(Any?.none as Any, Any?.none as Any))
        #expect(anyEquals(Any?.some(42) as Any, Any?.some(42) as Any))
        #expect(anyEquals(Any?.some(42) as Any, 42 as Any))
        #expect(anyEquals(Any?.none as Any, Any?.some(42) as Any) == false)
        #expect(anyEquals(Any?.some(1) as Any, Any?.some(2) as Any) == false)
    }
}
