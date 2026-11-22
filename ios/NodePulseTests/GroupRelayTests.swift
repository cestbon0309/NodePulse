import XCTest
import CryptoKit
@testable import NodePulse

final class GroupRelayTests: XCTestCase {
    private struct Vector: Decodable {
        let S: String
        let seed: String
        let enc_key: String
        let gid: String
        let slot: String
        let blob: String
        let message: String
        let signature: String
        let gget_message: String
        let gget_signature: String
        let gpush: Request
        struct Request: Decodable { let ts: Int; let rid: String }
    }
    private func vector() throws -> Vector {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "e2e-vector", withExtension: "json"))
        return try JSONDecoder().decode(Vector.self, from: Data(contentsOf: url))
    }
    private func bytes(_ hex: String) -> Data {
        Data(stride(from: 0, to: hex.count, by: 2).map { index in
            let start = hex.index(hex.startIndex, offsetBy: index)
            return UInt8(hex[start..<hex.index(start, offsetBy: 2)], radix: 16)!
        })
    }
    private func envelope(_ blobs: [[String: Any]], rid: String = "request") throws -> Data {
        try JSONSerialization.data(withJSONObject: ["ok": true, "rid": rid, "blobs": blobs])
    }
    func testCrossLanguageVector() throws {
        let v = try vector(), crypto = try GroupCrypto(secret: v.S)
        XCTAssertEqual(crypto.gid, v.gid)
        XCTAssertEqual(GroupCrypto.hex(crypto.signingKey.rawRepresentation), v.seed)
        XCTAssertEqual(crypto.encKey.withUnsafeBytes { GroupCrypto.hex(Data($0)) }, v.enc_key)
        XCTAssertEqual(crypto.slot(for: "vector-node"), v.slot)
        let node = try crypto.open(blob: v.blob, slot: v.slot)
        XCTAssertEqual(node.id, "vector-node"); XCTAssertEqual(node.name, "测试节点")
        XCTAssertEqual(node.ts, 1700000000)
        let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: bytes(v.gid))
        XCTAssertTrue(publicKey.isValidSignature(bytes(v.signature), for: Data(v.message.utf8)))
        XCTAssertTrue(publicKey.isValidSignature(bytes(v.gget_signature), for: Data(v.gget_message.utf8)))
        let request = try crypto.getRequest(timestamp: v.gpush.ts, requestID: v.gpush.rid)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: request.json) as? [String: Any])
        let generatedSignature = try XCTUnwrap(json["sig"] as? String)
        XCTAssertTrue(publicKey.isValidSignature(bytes(generatedSignature), for: Data(v.gget_message.utf8)))
        XCTAssertEqual(json["gid"] as? String, v.gid)
        XCTAssertEqual(json["rid"] as? String, v.gpush.rid)
        print("PASS CryptoKit C/Python vector: seed, gid, slot, blob, reference signatures and generated gget signature verification")
    }
    func testInvalidBlobsAreDroppedAndCounted() throws {
        let v = try vector(), crypto = try GroupCrypto(secret: v.S)
        var damaged = try XCTUnwrap(Data(base64Encoded: v.blob))
        damaged[15] ^= 1
        let wrongSlot = String(repeating: "0", count: 32)
        let forged = try ChaChaPoly.seal(Data(#"{"id":"different-id"}"#.utf8), using: crypto.encKey,
                                        authenticating: Data("\(v.gid):\(wrongSlot)".utf8)).combined.base64EncodedString()
        let blobs: [[String: Any]] = [
            ["slot": v.slot, "blob": damaged.base64EncodedString(), "age": 0],
            ["slot": wrongSlot, "blob": v.blob, "age": 0],
            ["slot": wrongSlot, "blob": forged, "age": 0],
            ["slot": v.slot, "blob": "not-base64", "age": 0],
            ["slot": v.slot, "blob": String(repeating: "A", count: 7172), "age": 0],
            ["slot": v.slot, "blob": v.blob, "age": -1],
            ["slot": v.slot, "blob": v.blob, "age": 2]
        ]
        let response = try crypto.decodeResponse(envelope(blobs), requestID: "request")
        XCTAssertEqual(response.snapshots.map(\.id), ["vector-node"])
        XCTAssertEqual(response.ages["vector-node"], 2)
        XCTAssertEqual(response.droppedBlobs, 6)
        XCTAssertThrowsError(try crypto.open(blob: v.blob, slot: wrongSlot))
        XCTAssertThrowsError(try GroupCrypto(secret: "wrong").open(blob: v.blob, slot: v.slot))
        XCTAssertThrowsError(try crypto.decodeResponse(envelope(blobs), requestID: "replayed-request"))
        XCTAssertThrowsError(try crypto.decodeResponse(Data("bad".utf8), requestID: "request"))
        XCTAssertThrowsError(try crypto.decodeResponse(envelope(Array(repeating: blobs.last!, count: 33)), requestID: "request"))
        let empty = try crypto.decodeResponse(envelope([]), requestID: "request")
        XCTAssertTrue(empty.snapshots.isEmpty); XCTAssertEqual(empty.droppedBlobs, 0)
    }
    func testRelayURLsAndStrongSecrets() throws {
        for input in ["https://example.com", "https://example.com/", "https://example.com/api/relay", "https://example.com/api/relay/"] {
            XCTAssertEqual(try GroupClient.relayURL(input).absoluteString, "https://example.com/api/relay")
        }
        XCTAssertEqual(try GroupClient.relayURL("http://127.0.0.1:19093/base/").path, "/base/api/relay")
        for invalid in ["http://example.com", "https://user:pass@example.com", "file:///api/relay"] {
            XCTAssertThrowsError(try GroupClient.relayURL(invalid))
        }
        let generated = (0..<64).map { _ in GroupCrypto.randomSecret() }
        XCTAssertEqual(Set(generated).count, 64)
        XCTAssertTrue(generated.allSatisfy { $0.count == 32 && $0.allSatisfy { "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_".contains($0) } })
    }
    @MainActor func testGroupFreshnessAndDroppedStatus() {
        let suite = "GroupFreshness-\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = MonitorStore(defaults: defaults)
        let endpoint = Endpoint(name: "group", kind: .groupTCP(host: "localhost", port: 1))
        let now = Date(timeIntervalSince1970: 10000)
        var node = NodeSnapshot(); node.id = "node"; node.ts = 9900
        store.apply(endpoint, result: .success([node]), latency: 1, now: now, ages: [node.id: 1], droppedBlobs: 3)
        XCTAssertTrue(store.nodes[0].online); XCTAssertTrue(store.nodes[0].endToEnd)
        XCTAssertEqual(store.statuses[endpoint.id]?.droppedBlobs, 3)
        store.apply(endpoint, result: .success([node]), latency: 1, now: now, ages: [node.id: 31])
        XCTAssertFalse(store.nodes[0].online)
        node.ts = 9940
        store.apply(endpoint, result: .success([node]), latency: 1, now: now, ages: [node.id: 100])
        XCTAssertEqual(store.nodes[0].probeInterval, 40); XCTAssertTrue(store.nodes[0].online)
        store.apply(endpoint, result: .success([node]), latency: 1, now: now, ages: [node.id: 161])
        XCTAssertFalse(store.nodes[0].online)
        for timestamp in [9399.0, 10601.0, nil] as [Double?] {
            node.ts = timestamp
            store.apply(endpoint, result: .success([node]), latency: 1, now: now, ages: [node.id: 0])
            XCTAssertFalse(store.nodes[0].online)
        }
        node.ts = 10000
        store.apply(endpoint, result: .success([node]), latency: 1, now: now, ages: [node.id: 0])
        XCTAssertTrue(store.nodes[0].online)
        store.apply(endpoint, result: .success([]), latency: 1, now: now, droppedBlobs: 1)
        XCTAssertFalse(store.nodes[0].online)
        XCTAssertEqual(store.statuses[endpoint.id]?.droppedBlobs, 1)
    }
    @MainActor func testGroupCredentialsPersistenceAndCleanup() throws {
        let suite = "GroupCredentials-\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let secrets = GroupMemorySecrets(), store = MonitorStore(defaults: defaults, secrets: secrets)
        var endpoint = Endpoint(name: "relay", kind: .groupHTTPS(urlString: "https://example.com"))
        XCTAssertThrowsError(try store.save(endpoint, secret: "token"))
        try store.save(endpoint, secret: "never-persist-token", groupSecret: "never-persist-group")
        XCTAssertEqual(try store.secret(for: endpoint), "never-persist-token")
        XCTAssertEqual(try store.groupSecret(for: endpoint), "never-persist-group")
        let persisted = String(data: defaults.data(forKey: "endpoints")!, encoding: .utf8)!
        XCTAssertFalse(persisted.contains("never-persist"))
        XCTAssertEqual(MonitorStore(defaults: defaults, secrets: secrets).endpoints, [endpoint])
        secrets.failNextSet = true
        XCTAssertThrowsError(try store.save(endpoint, secret: "replacement", groupSecret: "replacement-group"))
        XCTAssertEqual(try store.secret(for: endpoint), "never-persist-token")
        XCTAssertEqual(try store.groupSecret(for: endpoint), "never-persist-group")
        endpoint.kind = .https(urlString: "https://example.com")
        try store.save(endpoint, secret: "direct-secret")
        XCTAssertThrowsError(try store.groupSecret(for: endpoint))
        endpoint.kind = .groupTCP(host: "localhost", port: 1)
        try store.save(endpoint, secret: "token", groupSecret: "group")
        try store.delete(endpoint)
        XCTAssertTrue(store.endpoints.isEmpty)
        XCTAssertTrue(secrets.tokens.isEmpty); XCTAssertTrue(secrets.groups.isEmpty)
    }
    func testGroupKeychainItemsWhenSigned() throws {
        let secrets = SecretStore(), id = UUID()
        defer { try? secrets.delete(id); try? secrets.deleteGroup(id) }
        try secrets.set("relay-token", for: id); try secrets.setGroup("group-secret", for: id)
        XCTAssertEqual(try secrets.get(id), "relay-token")
        XCTAssertEqual(try secrets.getGroup(id), "group-secret")
        try secrets.setGroup("updated-group", for: id)
        XCTAssertEqual(try secrets.get(id), "relay-token")
        try secrets.deleteGroup(id)
        XCTAssertThrowsError(try secrets.getGroup(id))
        XCTAssertEqual(try secrets.get(id), "relay-token")
    }
    @MainActor func testLiveGroupRelay() async throws {
        guard ProcessInfo.processInfo.environment["NPULSE_E2E"] == "1" else {
            throw XCTSkip("Set NPULSE_E2E=1; relay 19092/19093 and two publishers with integration-group-secret")
        }
        let tcp = Endpoint(name: "relay TCP", kind: .groupTCP(host: "127.0.0.1", port: 19092))
        let http = Endpoint(name: "relay HTTP", kind: .groupHTTPS(urlString: "http://127.0.0.1:19093/"))
        let client = GroupClient()
        let direct = try await client.fetch(tcp, token: "integration-relay-token", groupSecret: "integration-group-secret")
        let web = try await client.fetch(http, token: "integration-relay-token", groupSecret: "integration-group-secret")
        XCTAssertEqual(direct.snapshots.count, 2); XCTAssertEqual(web.snapshots.count, 2)
        XCTAssertEqual(Set(direct.snapshots.map(\.id)), Set(web.snapshots.map(\.id)))
        XCTAssertEqual(direct.droppedBlobs, 0); XCTAssertEqual(web.droppedBlobs, 0)
        let suite = "LiveGroup-\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = MonitorStore(defaults: defaults, secrets: GroupMemorySecrets())
        try store.save(tcp, secret: "integration-relay-token", groupSecret: "integration-group-secret")
        await store.refresh()
        XCTAssertEqual(store.nodes.count, 2); XCTAssertTrue(store.nodes.allSatisfy { $0.online && $0.endToEnd })
        let tested = await store.testConnection(http, secret: "integration-relay-token", groupSecret: "integration-group-secret")
        XCTAssertEqual(try tested.get(), 2)
        do { _ = try await client.fetch(tcp, token: "wrong", groupSecret: "integration-group-secret"); XCTFail("wrong token accepted") }
        catch { XCTAssertEqual(error.localizedDescription, "密钥错误或被拒绝（对端静默断开）") }
        print("E2E PASS GroupClient TCP nodes=\(direct.snapshots.count), HTTP nodes=\(web.snapshots.count), dropped=0; store online/badges=2")
    }
}

private final class GroupMemorySecrets: SecretStorage {
    var tokens: [UUID: String] = [:]
    var groups: [UUID: String] = [:]
    var failNextSet = false
    func set(_ secret: String, for id: UUID) throws {
        if failNextSet { failNextSet = false; throw ProbeError.keychain(-1) }
        tokens[id] = secret
    }
    func get(_ id: UUID) throws -> String {
        guard let value = tokens[id] else { throw ProbeError.missingSecret }; return value
    }
    func delete(_ id: UUID) { tokens[id] = nil }
    func setGroup(_ secret: String, for id: UUID) { groups[id] = secret }
    func getGroup(_ id: UUID) throws -> String {
        guard let value = groups[id] else { throw ProbeError.missingSecret }; return value
    }
    func deleteGroup(_ id: UUID) { groups[id] = nil }
}
