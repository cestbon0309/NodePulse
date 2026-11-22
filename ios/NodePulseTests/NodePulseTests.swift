import XCTest
@testable import NodePulse

final class NodePulseTests: XCTestCase {
    func testCryptoRoundTrip() throws {
        let crypto = ProbeCrypto(secret: "秘密")
        let json = Data(#"{"op":"get","ts":1700000000}"#.utf8)
        XCTAssertEqual(try crypto.open(frame: crypto.seal(json: json)), json)
    }
    func testPythonFixedVector() throws {
        let hex = "0000001c000102030405060708090a0bee276e604b883ca74c7973e3cf57626c4247dd18b313a1f84d9617a8468fdd83c5d6dd03fdbe91af733f1e5d"
        let bytes = stride(from: 0, to: hex.count, by: 2).map { offset -> UInt8 in
            let start = hex.index(hex.startIndex, offsetBy: offset)
            return UInt8(hex[start..<hex.index(start, offsetBy: 2)], radix: 16)!
        }
        let crypto = ProbeCrypto(secret: "vector-secret")
        XCTAssertEqual(String(data: try crypto.open(frame: Data(bytes)), encoding: .utf8), #"{"op":"get","ts":1700000000}"#)
        var altered = Data(bytes); altered[altered.count - 1] ^= 1
        XCTAssertThrowsError(try crypto.open(frame: altered))
        XCTAssertThrowsError(try crypto.open(frame: Data(bytes.prefix(10))))
        XCTAssertThrowsError(try crypto.seal(json: Data()))
    }
    func testRealProbeAndMissingFields() throws {
        let sample = #"{"ok":true,"nodes":[{"id":"1b2efbfcf191aab6fd7615f7df9a77dfea87ba3c45c265da0ae4899f6c9e215c","name":"swift-test","hostname":"ip-172-16-4-2.us-west-2.compute.internal","os":"Darwin","kernel":"25.6.0","arch":"arm64","cpu_model":"","cpu_cores":12,"cpu_usage":0.0,"load":[4.42,12.72,12.77],"mem_total":0,"mem_used":0,"swap_total":0,"swap_used":0,"disk_total":131545956352,"disk_used":107959439360,"net_rx":0,"net_tx":0,"net_rx_rate":0.0,"net_tx_rate":0.0,"uptime":0.0,"procs":0,"tcp_conns":0,"temp":null,"ips":["172.16.4.2"],"ts":1795334822,"version":"0.1.0","relay":false}]}"#
        let node = try XCTUnwrap(ProbeResponse.decode(Data(sample.utf8)).first)
        XCTAssertEqual(node.cpuCores, 12); XCTAssertEqual(node.diskTotal, 131545956352)
        XCTAssertEqual(node.ips, ["172.16.4.2"]); XCTAssertNil(node.temp); XCTAssertNil(node.lastSeen)
        let partial = try ProbeResponse.decode(Data(#"{"ok":true,"nodes":[{"id":"minimal","unknown":123},{"id":"bad-field","cpu_usage":"oops"}]}"#.utf8))
        XCTAssertEqual(partial.count, 2); XCTAssertEqual(partial[0].load, [])
        XCTAssertEqual(partial[1].cpuUsage, 0)
        XCTAssertEqual(try ProbeResponse.decode(Data(#"{"ok":true,"nodes":[]}"#.utf8)), [])
        XCTAssertThrowsError(try ProbeResponse.decode(Data("bad".utf8)))
    }
    func testURLs() throws {
        for input in ["https://example.com", "https://example.com/", "https://example.com/api/nodes", "https://example.com/api/nodes/"] {
            XCTAssertEqual(try HTTPSClient.nodesURL(input).absoluteString, "https://example.com/api/nodes")
        }
        XCTAssertEqual(try HTTPSClient.nodesURL("http://localhost:123/base/").path, "/base/api/nodes")
        XCTAssertThrowsError(try HTTPSClient.nodesURL("http://example.com"))
        XCTAssertThrowsError(try HTTPSClient.nodesURL("file:///tmp/foo"))
    }
    @MainActor func testStoreHistoryOfflineDemoAndPersistence() throws {
        let suite = "NodePulseTests-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = MonitorStore(defaults: defaults, secrets: MemorySecrets())
        XCTAssertEqual(store.refreshInterval, 3)
        let endpoint = Endpoint(name: "test", kind: .direct(host: "localhost", port: 1))
        try store.save(endpoint, secret: "never-in-defaults")
        defer { try? store.delete(endpoint) }
        XCTAssertEqual(try store.secret(for: endpoint), "never-in-defaults")
        XCTAssertFalse(String(data: defaults.data(forKey: "endpoints")!, encoding: .utf8)!.contains("never-in-defaults"))
        XCTAssertEqual(MonitorStore(defaults: defaults).endpoints, [endpoint])
        var own = NodeSnapshot(); own.id = "self"; own.ts = 1000
        var relay = NodeSnapshot(); relay.id = "relay"; relay.ts = 950; relay.lastSeen = 950; relay.relay = true
        for _ in 0..<125 { store.apply(endpoint, result: .success([own, relay]), latency: 10) }
        XCTAssertEqual(store.nodes[0].history.count, 120)
        XCTAssertTrue(store.nodes[0].online); XCTAssertFalse(store.nodes[1].online)
        store.apply(endpoint, result: .failure(ProbeError.timeout), latency: 6000)
        XCTAssertEqual(store.nodes.count, 2); XCTAssertTrue(store.nodes.allSatisfy { !$0.online })
        XCTAssertEqual(store.statuses[endpoint.id]?.error, "超时")
        XCTAssertNotNil(store.statuses[endpoint.id]?.lastSuccess)
        store.demoMode = true
    }
    @MainActor func testDemo() async {
        let suite = "Demo-\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = MonitorStore(defaults: defaults); store.demoMode = true
        await store.refresh(); let first = store.nodes[0].snapshot.cpuUsage
        await store.refresh()
        XCTAssertEqual(store.nodes.count, 5); XCTAssertNotEqual(store.nodes[0].snapshot.cpuUsage, first)
        XCTAssertTrue(store.nodes.contains { !$0.online }); XCTAssertEqual(store.nodes[0].history.count, 2)
    }
    func testLiveProbe() async throws {
        guard ProcessInfo.processInfo.environment["NPULSE_E2E"] == "1" else {
            throw XCTSkip("Set NPULSE_E2E=1; run host probe on 19090/19091 with integration-secret")
        }
        let direct = Endpoint(name: "live", kind: .direct(host: "127.0.0.1", port: 19090))
        let http = Endpoint(name: "live", kind: .https(urlString: "http://127.0.0.1:19091/"))
        let nodes = try await DirectClient().fetch(direct, secret: "integration-secret")
        let webNodes = try await HTTPSClient().fetch(http, secret: "integration-secret")
        XCTAssertGreaterThanOrEqual(nodes.count, 1); XCTAssertGreaterThanOrEqual(webNodes.count, 1)
        print("E2E PASS DirectClient nodes=\(nodes.count), HTTPSClient localhost nodes=\(webNodes.count)")
        do { _ = try await DirectClient().fetch(direct, secret: "wrong"); XCTFail("wrong key accepted") }
        catch { XCTAssertEqual(error.localizedDescription, "密钥错误或被拒绝（对端静默断开）") }
        do { _ = try await HTTPSClient().fetch(http, secret: "wrong"); XCTFail("wrong HTTP key accepted") }
        catch { XCTAssertEqual(error.localizedDescription, "密钥错误或路径不对") }
    }
    func testKeychainWhenSigned() throws {
        let secrets = SecretStore(), id = UUID()
        do { try secrets.set("test-value", for: id) }
        catch ProbeError.keychain(-34018) { throw XCTSkip("Unsigned simulator app lacks Keychain entitlement (-34018); run signed to verify Security storage") }
        defer { try? secrets.delete(id) }
        XCTAssertEqual(try secrets.get(id), "test-value")
    }
}

private final class MemorySecrets: SecretStorage {
    var values: [UUID: String] = [:]
    func set(_ secret: String, for id: UUID) { values[id] = secret }
    func get(_ id: UUID) throws -> String {
        guard let value = values[id] else { throw ProbeError.missingSecret }
        return value
    }
    func delete(_ id: UUID) { values[id] = nil }
}
