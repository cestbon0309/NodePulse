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
    func getRequest(timestamp: Int = Int(Date().timeIntervalSince1970), requestID: String? = nil,
                    since: [String: HistoryCursor]? = nil) throws -> (json: Data, rid: String) {
        let rid = requestID ?? Self.hex(Data((0..<16).map { _ in UInt8.random(in: .min ... .max) }))
        var message = "npulse-gget\n\(gid)\n\(timestamp)\n\(rid)"
        var map: [String: Any]?
        if let since {
            map = since.mapValues { ["epoch": $0.epoch, "since": $0.since] as [String: Any] }
            let bytes = try JSONSerialization.data(withJSONObject: map!, options: [.sortedKeys, .withoutEscapingSlashes])
            message += "\n" + String(decoding: bytes, as: UTF8.self)
        }
        let signature = try signingKey.signature(for: Data(message.utf8))
        var object: [String: Any] = ["op": "gget", "ts": timestamp, "rid": rid, "gid": gid, "sig": Self.hex(signature)]
        if let map { object["since"] = map }
        return (try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]), rid)
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
        guard !node.id.isEmpty, self.slot(for: node.id) == slot else { throw ProbeError.transport(L10n.text("节点槽位校验失败")) }
        return node
    }
    func decodeResponse(_ data: Data, requestID: String) throws -> ProbeFetch {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["rid"] as? String == requestID else { throw ProbeError.transport(L10n.text("响应校验失败")) }
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
                if let history = item["history"] {
                    do { result.histories[node.id] = try openHistory(history, slot: slot) }
                    catch { result.invalidHistories.insert(node.id) }
                }
            } catch { result.droppedBlobs += 1 }
        }
        return result
    }
    func openHistory(_ object: Any, slot: String) throws -> HistoryBatch {
        struct Envelope: Decodable {
            struct Record: Decodable {
                var seq: UInt32
                var blob: String
                init(from decoder: Decoder) throws {
                    var container = try decoder.unkeyedContainer()
                    seq = try container.decode(UInt32.self); blob = try container.decode(String.self)
                    guard container.isAtEnd else { throw ProbeError.parse }
                }
            }
            var epoch: String
            var seq: UInt32
            var full: Bool
            var samples: [Record]
        }
        struct Plain: Decodable { var epoch: String; var sample: [Double] }
        let envelope = try JSONDecoder().decode(Envelope.self, from: JSONSerialization.data(withJSONObject: object))
        guard envelope.samples.count <= 120 else { throw ProbeError.parse }
        let rows = try envelope.samples.map { record -> [Double] in
            guard record.blob.utf8.count <= 384, let data = Data(base64Encoded: record.blob) else { throw ProbeError.parse }
            let ad = Data("npulse-history-v1:\(gid):\(slot):\(envelope.epoch):\(record.seq)".utf8)
            let bytes = try ChaChaPoly.open(ChaChaPoly.SealedBox(combined: data), using: encKey, authenticating: ad)
            let plain = try JSONDecoder().decode(Plain.self, from: bytes)
            guard plain.epoch == envelope.epoch, plain.sample.first == Double(record.seq) else { throw ProbeError.parse }
            return plain.sample
        }
        let batch = HistoryBatch(epoch: envelope.epoch, seq: envelope.seq, full: envelope.full, samples: rows)
        _ = try batch.points()
        return batch
    }
}

struct ProbeFetch {
    var snapshots: [NodeSnapshot] = []
    var ages: [String: Double] = [:]
    var droppedBlobs = 0
    var histories: [String: HistoryBatch] = [:]
    var invalidHistories: Set<String> = []
    var legacyRelay = false
    static func direct(_ data: Data) throws -> ProbeFetch {
        let snapshots = try ProbeResponse.decode(data)
        var result = ProbeFetch(snapshots: snapshots)
        if let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
           let history = object["history"], let node = snapshots.first {
            do {
                let batch = try JSONDecoder().decode(HistoryBatch.self, from: JSONSerialization.data(withJSONObject: history))
                _ = try batch.points(); result.histories[node.id] = batch
            } catch { result.invalidHistories.insert(node.id) }
        }
        return result
    }
}
