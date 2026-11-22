import CryptoKit
import Foundation

struct AdminCrypto {
    static func bytes(_ hex: String, count: Int) throws -> Data {
        guard hex.count == count * 2 else { throw AdminError.handshake }
        var result = Data()
        var index = hex.startIndex
        while index != hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { throw AdminError.handshake }
            result.append(byte); index = next
        }
        return result
    }
    static func length(_ count: Int) -> Data {
        let n = UInt32(count)
        return Data([UInt8(n >> 24), UInt8((n >> 16) & 255), UInt8((n >> 8) & 255), UInt8(n & 255)])
    }
    static func ackMAC(secret: String, rid: String, client: String, probe: String) -> Data {
        let key = SymmetricKey(data: Data(SHA512.hash(data: Data(("npulse-admin-id:" + secret).utf8))).prefix(32))
        return Data(HMAC<SHA512>.authenticationCode(for: Data("npulse-admin-ack\n\(rid)\n\(client)\n\(probe)".utf8), using: key).prefix(32))
    }
    static func verifyACK(_ ack: [String: Any], secret: String, rid: String, client: String) throws -> Data {
        guard ack["ok"] as? Bool == true, ack["rid"] as? String == rid,
              let epk = ack["epk"] as? String, let mac = ack["mac"] as? String else { throw AdminError.handshake }
        let key = try bytes(epk, count: 32), tag = try bytes(mac, count: 32)
        let expected = ackMAC(secret: secret, rid: rid, client: client, probe: epk)
        guard zip(tag, expected).reduce(UInt8(0), { $0 | ($1.0 ^ $1.1) }) == 0 else { throw AdminError.handshake }
        return key
    }
    static func keys(ephemeral: Curve25519.KeyAgreement.PrivateKey, peer: Data) throws -> Data {
        let shared = try ephemeral.sharedSecretFromKeyAgreement(with: Curve25519.KeyAgreement.PublicKey(rawRepresentation: peer))
        return shared.withUnsafeBytes { raw in
            Data(SHA512.hash(data: Data("npulse-admin-sess".utf8) + Data(raw) + ephemeral.publicKey.rawRepresentation + peer))
        }
    }
}

struct AdminCipher {
    let key: SymmetricKey
    private(set) var counter: UInt64 = 0
    init(key: Data) { self.key = SymmetricKey(data: key) }
    private func nonce() throws -> ChaChaPoly.Nonce {
        guard counter < UInt64.max else { throw AdminError.disconnected }
        return try ChaChaPoly.Nonce(data: Data((0..<8).map { UInt8(truncatingIfNeeded: counter >> ($0 * 8)) }) + Data(repeating: 0, count: 4))
    }
    mutating func seal(_ data: Data) throws -> Data {
        guard !data.isEmpty, data.count <= 131072 else { throw AdminError.message("管理消息过大") }
        let header = AdminCrypto.length(data.count)
        let box = try ChaChaPoly.seal(data, using: key, nonce: nonce(), authenticating: header)
        counter += 1
        return header + box.ciphertext + box.tag
    }
    mutating func open(_ frame: Data) throws -> Data {
        let n = try ProbeCrypto.length(Data(frame.prefix(4)))
        guard n <= 131072, frame.count == n + 20 else { throw AdminError.disconnected }
        let box = try ChaChaPoly.SealedBox(nonce: nonce(), ciphertext: frame.dropFirst(4).prefix(n), tag: frame.suffix(16))
        let plain = try ChaChaPoly.open(box, using: key, authenticating: frame.prefix(4))
        counter += 1
        return plain
    }
}
