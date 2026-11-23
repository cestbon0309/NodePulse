import Foundation
import CryptoKit

struct ProbeCrypto {
    static let maxLength = 2 * 1024 * 1024
    let key: SymmetricKey
    init(secret: String) { key = SymmetricKey(data: Data(SHA512.hash(data: Data(secret.utf8))).prefix(32)) }
    func seal(json: Data) throws -> Data {
        guard !json.isEmpty, json.count <= Self.maxLength else { throw ProbeError.parse }
        let n = UInt32(json.count)
        let length = Data([UInt8(n >> 24), UInt8((n >> 16) & 255), UInt8((n >> 8) & 255), UInt8(n & 255)])
        let box = try ChaChaPoly.seal(json, using: key, authenticating: length)
        return length + box.nonce.withUnsafeBytes { Data($0) } + box.ciphertext + box.tag
    }
    static func length(_ data: Data) throws -> Int {
        guard data.count == 4 else { throw ProbeError.parse }
        let n = data.reduce(0) { ($0 << 8) | Int($1) }
        guard n > 0, n <= maxLength else { throw ProbeError.parse }
        return n
    }
    func open(frame: Data) throws -> Data {
        guard frame.count >= 32 else { throw ProbeError.parse }
        let length = Data(frame.prefix(4))
        let n = try Self.length(length)
        guard frame.count == n + 32 else { throw ProbeError.parse }
        do {
            let box = try ChaChaPoly.SealedBox(nonce: ChaChaPoly.Nonce(data: frame.dropFirst(4).prefix(12)),
                                              ciphertext: frame.dropFirst(16).prefix(n), tag: frame.suffix(16))
            return try ChaChaPoly.open(box, using: key, authenticating: length)
        } catch { throw ProbeError.rejected }
    }
}
