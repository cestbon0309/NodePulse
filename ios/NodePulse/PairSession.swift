import CryptoKit
import Foundation

struct PairResult: Decodable {
    let ok: Bool
    let key: String?
    let mode: String?
    let group: String?
    let node: String
    let name: String
    let port: UInt16?
    let admin: Bool
}

actor PairSession {
    nonisolated let art: String
    nonisolated let code: String
    private let channel: AdminConnection
    private var tx: AdminCipher
    private var rx: AdminCipher
    private var confirmed = false
    private init(channel: AdminConnection, keys: Data) {
        self.channel = channel
        tx = AdminCipher(key: keys.prefix(32)); rx = AdminCipher(key: keys.suffix(32))
        let sas = PairCrypto.sas(keys)
        art = PairCrypto.art(sas); code = PairCrypto.code(sas)
    }
    private static func plain(_ json: [String: Any]) throws -> Data {
        let data = try JSONSerialization.data(withJSONObject: json, options: [.withoutEscapingSlashes])
        guard !data.isEmpty, data.count <= 4096 else { throw PairError.handshake }
        return AdminCrypto.length(data.count) + data
    }
    static func connect(host: String, port: UInt16, relayToken: String? = nil, code: String? = nil, psk: Data? = nil) async throws -> PairSession {
        let channel = try AdminConnection(host: host, port: port)
        do {
            try await channel.open()
            if let relayToken {
                guard let code else { throw PairError.handshake }
                let request: [String: Any] = ["op": "pconnect", "code": code, "ts": Int(Date().timeIntervalSince1970), "rid": UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()]
                let outer = ProbeCrypto(secret: relayToken)
                try await channel.send(outer.seal(json: JSONSerialization.data(withJSONObject: request)))
                let body = try outer.open(frame: await channel.readFrame(overhead: 28, limit: 4096))
                guard let ack = try JSONSerialization.jsonObject(with: body) as? [String: Any], ack["ok"] as? Bool == true else { throw PairError.handshake }
            }
            let key = Curve25519.KeyAgreement.PrivateKey(), pub = key.publicKey.rawRepresentation
            try await channel.send(plain(["op": "pair", "v": 1, "commit": GroupCrypto.hex(PairCrypto.commit(pub)), "psk": psk != nil]))
            let frame = try await channel.readFrame(overhead: 0, limit: 4096)
            guard let response = try JSONSerialization.jsonObject(with: frame.dropFirst(4)) as? [String: Any],
                  let epk = response["epk"] as? String else { throw PairError.handshake }
            let peer: Data
            do { peer = try AdminCrypto.bytes(epk, count: 32) } catch { throw PairError.handshake }
            let keys: Data
            do { keys = try PairCrypto.keys(privateKey: key, peer: peer, psk: psk) } catch { throw PairError.handshake }
            try await channel.send(plain(["epk": GroupCrypto.hex(pub)]))
            return PairSession(channel: channel, keys: keys)
        } catch {
            channel.cancel(); throw PairError.transport(error)
        }
    }
    func confirm(_ accepted: Bool, name: String, adminKey: Data? = nil) async throws -> PairResult {
        guard !confirmed else { throw PairError.handshake }
        confirmed = true
        defer { channel.cancel() }
        do {
            var message: [String: Any] = ["op": accepted ? "confirm" : "reject"]
            if accepted {
                message["name"] = name
                if let adminKey { message["admin_pk"] = GroupCrypto.hex(adminKey) }
                else { message["admin_pk"] = NSNull() }
            }
            let data = try JSONSerialization.data(withJSONObject: message, options: [.withoutEscapingSlashes])
            guard data.count <= 4096 else { throw PairError.handshake }
            try await channel.send(tx.seal(data))
            let frame = try await channel.readFrame(overhead: 16, limit: 4096)
            let plain: Data
            do { plain = try rx.open(frame) } catch { throw PairError.handshake }
            guard let response = try JSONSerialization.jsonObject(with: plain) as? [String: Any] else { throw PairError.handshake }
            guard response["ok"] as? Bool == true else { throw PairError.rejected }
            let result = try JSONDecoder().decode(PairResult.self, from: plain)
            let valid = result.mode == "relay" ? !(result.group ?? "").isEmpty : !(result.key ?? "").isEmpty && (result.port ?? 0) > 0
            guard accepted, valid,
                  (try? AdminCrypto.bytes(result.node, count: 32)) != nil else { throw PairError.handshake }
            return result
        } catch { throw PairError.transport(error) }
    }
    nonisolated func close() { channel.cancel() }
}
