/// Fingerprints persisted identities with FNV-1a instead of Swift's process-randomized Hasher.
///
/// Keep the byte order and unpadded hexadecimal representation unchanged for checkpoint and build compatibility.
package enum StableHash {
    /// Hashes UTF-8 bytes without platform-dependent integer encoding.
    package static func hex(_ value: String) -> String {
        let hash = value.utf8.reduce(UInt64(14_695_981_039_346_656_037)) {
            ($0 ^ UInt64($1)) &* 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }

    /// Separates fields by their UTF-8 lengths so embedded delimiters cannot merge different identities.
    package static func fields(_ values: [String]) -> String {
        let fingerprint = hex(values.map { "\($0.utf8.count):\($0)" }.joined())
        return String(repeating: "0", count: 16 - fingerprint.count) + fingerprint
    }
}
