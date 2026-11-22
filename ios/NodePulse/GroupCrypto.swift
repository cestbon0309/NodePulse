import Foundation
import CryptoKit

struct GroupCrypto {
    static let maxBlob = 7168
    let encKey: SymmetricKey
    let signingKey: Curve25519.Signing.PrivateKey
    var gid: String { Self.hex(signingKey.publicKey.rawRepresentation) }
    init(secret: String) throws {
        encKey = SymmetricKey(data: Self.derive("npulse-e2e-enc:", secret: secret))
        signingKey = try Curve25519.Signing.PrivateKey(rawRepresentation: Self.derive("npulse-e2e-sign:", secret: secret))
    }
    private static func derive(_ prefix: String, secret: String) -> Data {
        Data(SHA512.hash(data: Data((prefix + secret).utf8)).prefix(32))
    }
    static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
    static func randomSecret() -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        return String((0..<32).map { _ in alphabet.randomElement()! })
    }
    func slot(for id: String) -> String {
        let input = Data("npulse-e2e-slot:".utf8) + encKey.withUnsafeBytes { Data($0) } + Data(id.utf8)
        return Self.hex(Data(SHA512.hash(data: input).prefix(16)))
    }
    func getRequest(timestamp: Int = Int(Date().timeIntervalSince1970), requestID: String? = nil) throws -> (json: Data, rid: String) {
        let rid = requestID ?? Self.hex(Data((0..<16).map { _ in UInt8.random(in: .min ... .max) }))
        let message = Data("npulse-gget\n\(gid)\n\(timestamp)\n\(rid)".utf8)
        let signature = try signingKey.signature(for: message)
        return (try JSONSerialization.data(withJSONObject: ["op": "gget", "ts": timestamp,
                                                             "rid": rid, "gid": gid, "sig": Self.hex(signature)]), rid)
    }
    func open(blob: String, slot: String) throws -> NodeSnapshot {
        guard blob.utf8.count <= Self.maxBlob, let combined = Data(base64Encoded: blob),
              combined.count >= 28, slot.utf8.count == 32,
              slot.allSatisfy({ "0123456789abcdef".contains($0) }) else { throw ProbeError.parse }
        let box = try ChaChaPoly.SealedBox(combined: combined)
        let data = try ChaChaPoly.open(box, using: encKey, authenticating: Data("\(gid):\(slot)".utf8))
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let node = try decoder.decode(NodeSnapshot.self, from: data)
        guard !node.id.isEmpty, self.slot(for: node.id) == slot else { throw ProbeError.transport("节点槽位校验失败") }
        return node
    }
    func decodeResponse(_ data: Data, requestID: String) throws -> ProbeFetch {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["rid"] as? String == requestID else { throw ProbeError.transport("响应校验失败") }
        guard object["ok"] as? Bool == true, let blobs = object["blobs"] as? [Any], blobs.count <= 32 else { throw ProbeError.parse }
        var result = ProbeFetch()
        var slots = Set<String>()
        for item in blobs {
            do {
                guard let item = item as? [String: Any], let slot = item["slot"] as? String,
                      let blob = item["blob"] as? String, let age = item["age"] as? Double,
                      age.isFinite, age >= 0, !slots.contains(slot) else { throw ProbeError.parse }
                let node = try open(blob: blob, slot: slot)
                slots.insert(slot)
                result.snapshots.append(node)
                result.ages[node.id] = age
            } catch { result.droppedBlobs += 1 }
        }
        return result
    }
}

struct ProbeFetch {
    var snapshots: [NodeSnapshot] = []
    var ages: [String: Double] = [:]
    var droppedBlobs = 0
}
