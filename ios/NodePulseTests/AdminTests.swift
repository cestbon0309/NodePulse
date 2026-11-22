import CryptoKit
import Security
import XCTest
@testable import NodePulse

final class AdminTests: XCTestCase {
    func testPythonHandshakeAndCounterVector() throws {
        let client = "07a37cbc142093c8b755dc1b10e86cb426374ad16aa853ed0bdfc0b2b86d1c7c"
        let probe = "ad438bfae31f6c093d61d4339255ea798092c9fadd07b97827f4b0ae9dee7c1c"
        let rid = "00112233445566778899aabbccddeeff", secret = "admin-vector-秘密"
        let mac = "3d6a1c0e475f36a637958d6af12516e71c57eb357875edd02d644dc43da11939"
        let expected = "d809619e051461eed46da390fb975c069b11d756c0487aa5f6c5304b384c42cb2adf047adad45764504613e8e51cece9524d874d964ff950f32cc8acd9728b42"
        let ephemeral = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(1...32))
        XCTAssertEqual(GroupCrypto.hex(ephemeral.publicKey.rawRepresentation), client)
        XCTAssertEqual(GroupCrypto.hex(AdminCrypto.ackMAC(secret: secret, rid: rid, client: client, probe: probe)), mac)
        let keys = try AdminCrypto.keys(ephemeral: ephemeral, peer: AdminCrypto.bytes(probe, count: 32))
        XCTAssertEqual(GroupCrypto.hex(keys), expected)
        let ack: [String: Any] = ["ok": true, "rid": rid, "epk": probe, "mac": mac]
        XCTAssertEqual(try AdminCrypto.verifyACK(ack, secret: secret, rid: rid, client: client), try AdminCrypto.bytes(probe, count: 32))
        XCTAssertThrowsError(try AdminCrypto.verifyACK(ack, secret: "wrong", rid: rid, client: client))
        XCTAssertThrowsError(try AdminCrypto.verifyACK(ack, secret: secret, rid: "wrong", client: client))
        XCTAssertThrowsError(try AdminCrypto.bytes("invalid", count: 32))
        var tx = AdminCipher(key: Data(keys.prefix(32))), rx = AdminCipher(key: Data(keys.prefix(32)))
        let plain = Data(#"{"t":"ping","id":1}"#.utf8), frame = try tx.seal(plain)
        XCTAssertEqual(GroupCrypto.hex(frame), "000000137b40f53d5908f27257ca2aa89fcd9a90272edc48a259ad926c8fa45e56734b93883673")
        XCTAssertEqual(try rx.open(frame), plain)
        XCTAssertThrowsError(try rx.open(frame))
        var bad = frame; bad[bad.count - 1] ^= 1
        var fresh = AdminCipher(key: Data(keys.prefix(32)))
        XCTAssertThrowsError(try fresh.open(bad))
        XCTAssertEqual(fresh.counter, 0)
        XCTAssertThrowsError(try tx.seal(Data()))
        XCTAssertThrowsError(try tx.seal(Data(repeating: 0, count: 131073)))
        print("PASS Python/CryptoKit admin vector: X25519, ACK HMAC/rid, directional SHA512 keys, counter-0 AEAD; replay/tag/empty/oversize rejected")
    }
    func testAdminIdentityKeychainWhenUnlocked() throws {
        let identity = try AdminIdentity.load() ?? AdminIdentity.generate()
        let reloaded = try XCTUnwrap(AdminIdentity.load())
        XCTAssertEqual(identity.publicKey.rawRepresentation, reloaded.publicKey.rawRepresentation)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "nodepulse.admin",
            kSecAttrAccount as String: "ed25519", kSecReturnAttributes as String: true]
        var result: CFTypeRef?
        XCTAssertEqual(SecItemCopyMatching(query as CFDictionary, &result), errSecSuccess)
        XCTAssertEqual((result as? [String: Any])?[kSecAttrAccessible as String] as? String, kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
        print("PASS admin identity Keychain round trip; accessible WhenUnlockedThisDeviceOnly")
    }
    @MainActor func testAdminFileNamesAndTransportEligibility() {
        XCTAssertTrue(AdminFilesModel.validName("测试文件.txt"))
        for name in ["", ".", "..", "../escape", "a/b", "bad\0name"] { XCTAssertFalse(AdminFilesModel.validName(name)) }
        XCTAssertNil(AdminFile(["name": "../escape", "type": "f"]))
        XCTAssertTrue(AdminSession.supports(.direct(host: "localhost", port: 9000)))
        XCTAssertTrue(AdminSession.supports(.groupTCP(host: "localhost", port: 9010)))
        XCTAssertFalse(AdminSession.supports(.https(urlString: "https://example.com")))
        XCTAssertFalse(AdminSession.supports(.groupHTTPS(urlString: "https://example.com")))
    }
    func testLiveDirectAndRelayAdmin() async throws {
        guard ProcessInfo.processInfo.environment["NPULSE_ADMIN_E2E"] == "1" else { throw XCTSkip("Run probe/tools/ios-admin-fixtures.py; set NPULSE_ADMIN_E2E=1") }
        let signing = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 0x42, count: 32))
        let direct = Endpoint(name: "admin direct", kind: .direct(host: "127.0.0.1", port: 19094))
        let relay = Endpoint(name: "admin relay", kind: .groupTCP(host: "127.0.0.1", port: 19095))
        let nodes = try await DirectClient().fetch(direct, secret: "integration-admin-secret")
        let node = try XCTUnwrap(nodes.first)
        for endpoint in [direct, relay] {
            let session = try await AdminSession.connect(endpoint: endpoint, node: node.id,
                secret: endpoint.kind.isGroup ? "admin-relay-token" : "integration-admin-secret", groupSecret: "admin-relay-group", signing: signing)
            let info = try await session.request("info")
            let home = try XCTUnwrap(info["home"] as? String), root = home + "/.npulse-ios-test-" + UUID().uuidString
            _ = try await session.request("mkdir", ["path": root])
            do {
                let listing = try await session.request("ls", ["path": root])
                XCTAssertEqual((listing["entries"] as? [[String: Any]])?.count, 0)
                let data = Data((0..<(200 * 1024)).map { UInt8(truncatingIfNeeded: $0) })
                let upload = try await session.request("put_begin", ["path": root + "/roundtrip.bin", "size": data.count, "overwrite": false])
                let handle = try XCTUnwrap(upload["handle"] as? Int)
                for offset in stride(from: 0, to: data.count, by: 65536) {
                    let chunk = data.subdata(in: offset..<min(data.count, offset + 65536))
                    _ = try await session.request("put", ["handle": handle, "offset": offset, "data": chunk.base64EncodedString()])
                }
                _ = try await session.request("put_end", ["handle": handle])
                var downloaded = Data()
                while downloaded.count < data.count {
                    let response = try await session.request("get", ["path": root + "/roundtrip.bin", "offset": downloaded.count, "len": 65536])
                    let chunk = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(response["data"] as? String)))
                    XCTAssertFalse(chunk.isEmpty); if chunk.isEmpty { throw AdminError.disconnected }
                    downloaded += chunk
                }
                XCTAssertEqual(Data(SHA256.hash(data: data)), Data(SHA256.hash(data: downloaded)))
                let end = try await session.request("get", ["path": root + "/roundtrip.bin", "offset": data.count, "len": 65536])
                XCTAssertEqual(end["data"] as? String, ""); XCTAssertEqual(end["eof"] as? Bool, true)
                let empty = try await session.request("put_begin", ["path": root + "/empty", "size": 0, "overwrite": false])
                _ = try await session.request("put_end", ["handle": try XCTUnwrap(empty["handle"] as? Int)])
                let zero = try await session.request("get", ["path": root + "/empty", "offset": 0, "len": 65536])
                XCTAssertEqual(zero["data"] as? String, ""); XCTAssertEqual(zero["eof"] as? Bool, true)
                let aborted = try await session.request("put_begin", ["path": root + "/aborted", "size": 65536, "overwrite": false])
                _ = try await session.request("put_abort", ["handle": try XCTUnwrap(aborted["handle"] as? Int)])
                let final = try await session.request("ls", ["path": root])
                XCTAssertEqual((final["entries"] as? [[String: Any]])?.count, 2)
                do { _ = try await session.request("ls", ["path": root + "/missing"]); XCTFail("missing directory accepted") }
                catch { XCTAssertTrue(error.localizedDescription.contains("操作失败")) }
                async let ping = session.request("ping")
                async let metadata = session.request("info")
                _ = try await (ping, metadata)
                let pty = try await session.request("pty_open", ["cols": 80, "rows": 24])
                let id = try XCTUnwrap(pty["pty"] as? Int)
                _ = try await session.request("pty_resize", ["pty": id, "cols": 100, "rows": 35])
                try await session.input(pty: id, data: Data("echo hi; exit 3\n".utf8))
                let deadline = Task { do { try await Task.sleep(for: .seconds(12)); await session.close() } catch {} }
                var output = Data(), exitCode: Int?
                for await event in session.events {
                    switch event {
                    case .output(let pty, let data) where pty == id: output += data
                    case .exit(let pty, let code) where pty == id: exitCode = code
                    default: break
                    }
                    if exitCode != nil { break }
                }
                deadline.cancel()
                XCTAssertTrue(String(decoding: output, as: UTF8.self).contains("hi")); XCTAssertEqual(exitCode, 3)
                _ = try await session.request("rm", ["path": root, "recursive": true]); await session.close()
                do { _ = try await session.request("ping"); XCTFail("closed session accepted request") }
                catch { XCTAssertTrue(error.localizedDescription.contains("断开")) }
                print("E2E PASS AdminSession \(endpoint.kind.isGroup ? "relay" : "direct"): hello/MAC, empty ls, 200KB put/get SHA256, empty/EOF/abort/errors, concurrent ids, PTY resize/echo hi/exit 3")
            } catch { _ = try? await session.request("rm", ["path": root, "recursive": true]); await session.close(); throw error }
        }
        do {
            let session = try await AdminSession.connect(endpoint: direct, node: node.id, secret: "integration-admin-secret", signing: Curve25519.Signing.PrivateKey())
            await session.close(); XCTFail("unauthorized key accepted")
        } catch { XCTAssertTrue(error.localizedDescription.contains("未授权")) }
        do {
            let session = try await AdminSession.connect(endpoint: relay, node: "offline", secret: "admin-relay-token", groupSecret: "admin-relay-group", signing: signing)
            await session.close(); XCTFail("offline node accepted")
        } catch { XCTAssertTrue(error.localizedDescription.contains("节点离线")) }
    }
}
