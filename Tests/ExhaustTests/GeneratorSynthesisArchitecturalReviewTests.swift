import Exhaust
import ExhaustCore
import Foundation
import Testing

@Suite("Generator synthesis architectural review")
struct GeneratorSynthesisReviewTests {
    @Test("Out-of-range integers are rejected like JSONDecoder")
    func outOfRangeIntegerIsRejected() throws {
        let json = """
        {"value": 300}
        """
        let data = try #require(json.data(using: .utf8))

        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(ByteRecord.self, from: data)
        }
        #expect(throws: DecodingError.self) {
            _ = try #gen(ByteRecord.self, from: data)
        }
    }

    @Test("Nested Data uses the JSONDecoder representation")
    func nestedDataUsesJSONDecoderRepresentation() throws {
        let json = """
        {"payload": "AQID"}
        """
        let data = try #require(json.data(using: .utf8))
        let decoded = try JSONDecoder().decode(DataRecord.self, from: data)

        #expect(decoded.payload == Data([1, 2, 3]))
        do {
            _ = try #gen(DataRecord.self, from: data)
        } catch {
            Issue.record("Expected synthesis to accept JSON that JSONDecoder accepts: \(error)")
        }
    }

    @Test("Present values with a mismatched optional type trigger fallback")
    func mismatchedOptionalTypeTriggersFallback() throws {
        let generator = try #gen(TypeSwitchingRecord.self, from: """
        {"flag": true, "payload": {"number": 7}}
        """)
        let values = try #example(generator, count: 80, seed: 1337)
        let uncoveredBranchCount = values.count(where: { $0.flag == false })

        #expect(uncoveredBranchCount == 0)
    }

    @Test("Fixed positional decoding is not inferred as a variable-length array")
    func fixedPositionalDecodeIsNotHomogeneousArray() throws {
        let decoder = DiscoveryDecoder(jsonValue: [1, 2])
        _ = try FixedPair(from: decoder)

        guard case .unkeyed = decoder.shape else {
            Issue.record("Expected two explicit positional decodes to retain a fixed unkeyed shape")
            return
        }
    }
}

private struct ByteRecord: Decodable {
    let value: UInt8
}

private struct DataRecord: Decodable {
    let payload: Data
}

private struct FirstPayload: Decodable {
    let number: Int
}

private struct SecondPayload: Decodable {
    let text: String
}

private struct TypeSwitchingRecord: Decodable {
    let flag: Bool
    let firstPayload: FirstPayload?
    let secondPayload: SecondPayload?

    private enum CodingKeys: String, CodingKey {
        case flag
        case payload
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        flag = try container.decode(Bool.self, forKey: .flag)
        if flag {
            firstPayload = try container.decode(FirstPayload.self, forKey: .payload)
            secondPayload = nil
        } else {
            firstPayload = nil
            secondPayload = try container.decodeIfPresent(SecondPayload.self, forKey: .payload)
        }
    }
}

private struct FixedPair: Decodable {
    let first: Int
    let second: Int

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        first = try container.decode(Int.self)
        second = try container.decode(Int.self)
    }
}
