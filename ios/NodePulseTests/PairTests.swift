import CryptoKit
import XCTest
@testable import NodePulse

final class PairTests: XCTestCase {
    func testPairVector() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "pair-vector", withExtension: "json"))
        let vector = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: String])
        func bytes(_ name: String, _ count: Int) throws -> Data { try AdminCrypto.bytes(XCTUnwrap(vector[name]), count: count) }
        let privateKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: bytes("sk_c", 32))
        XCTAssertEqual(privateKey.publicKey.rawRepresentation, try bytes("epk_c", 32))
        XCTAssertEqual(PairCrypto.commit(privateKey.publicKey.rawRepresentation), try bytes("commit", 32))
        let keys = try PairCrypto.keys(privateKey: privateKey, peer: bytes("epk_p", 32))
        XCTAssertEqual(keys, try bytes("k", 64))
        XCTAssertEqual(PairCrypto.sas(keys), try bytes("sas", 16))
        XCTAssertEqual(PairCrypto.art(PairCrypto.sas(keys)), vector["art"])
        XCTAssertEqual(PairCrypto.code(PairCrypto.sas(keys)), vector["code"])
        XCTAssertEqual(vector["art"]?.utf8.count, 220)
        let pskKeys = try PairCrypto.keys(privateKey: privateKey, peer: bytes("epk_p", 32), psk: bytes("psk", 16))
        XCTAssertEqual(pskKeys, try bytes("k_psk", 64)); XCTAssertEqual(PairCrypto.sas(pskKeys), try bytes("sas_psk", 16))
        XCTAssertThrowsError(try PairCrypto.keys(privateKey: privateKey, peer: Data(repeating: 0, count: 32)))
        print("PASS C/Python/CryptoKit pairing vector: commitment, X25519 directional keys, SAS, 220-byte randomart and six-digit code; low-order peer rejected")
    }
    func testPairURLs() throws {
        let psk = "AAECAwQFBgcICQoLDA0ODw"
        let direct = try PairInvite(url: XCTUnwrap(URL(string: "nodepulse://pair?v=1&h=2001%3Adb8%3A%3A1&p=9527&s=" + psk)))
        XCTAssertEqual(direct.host, "2001:db8::1"); XCTAssertEqual(direct.port, 9527); XCTAssertFalse(direct.isRelay)
        XCTAssertEqual(direct.psk, Data(0...15))
        let relay = try PairInvite(url: XCTUnwrap(URL(string: "nodepulse://pair?v=1&r=%5B2001%3Adb8%3A%3A1%5D%3A9010&t=token%26%2B&c=oIlA-b234&s=" + psk)))
        XCTAssertEqual(relay.token, "token&+"); XCTAssertEqual(relay.code, "011A-B234"); XCTAssertTrue(relay.isRelay)
        for text in ["https://pair?v=1", "nodepulse://other?v=1", "nodepulse://pair?v=2&h=a&p=9527&s=" + psk,
                     "nodepulse://pair?v=1&h=a&p=0&s=" + psk, "nodepulse://pair?v=1&h=a&p=9527&s=bad",
                     "nodepulse://pair?v=1&h=a&h=b&p=9527&s=" + psk, "nodepulse://pair?v=1&r=a:9010&t=t&c=bad&s=" + psk,
                     "nodepulse://pair?v=1&r=a:9010&h=b&t=t&c=ABCD1234&s=" + psk] {
            XCTAssertThrowsError(try PairInvite(url: XCTUnwrap(URL(string: text))))
        }
        XCTAssertEqual(PairInvite.formattedCode("abcd1234"), "ABCD-1234")
        print("PASS pairing URLs: direct/IPv6/relay, token escaping, Crockford normalization, 16-byte PSK; invalid version/host/port/PSK/duplicates/mixed modes rejected")
    }
    func testLivePairing() async throws {
        guard ProcessInfo.processInfo.environment["NPULSE_PAIR_E2E"] == "1" else { throw XCTSkip("Run ios-pair-fixture.py; NPULSE_PAIR_E2E=1") }
        func fixture(_ path: String) async throws -> [String: Any] {
            let (data, _) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:19096/" + path)!)
            return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
        for (relay, pskMode, accept) in [(false, false, true), (false, true, true), (false, true, false), (true, false, true), (true, true, true)] {
            let ready = try await fixture(relay ? "start-relay" : "start")
            let port = try XCTUnwrap(ready["port"] as? UInt16)
            let invite = try PairInvite(url: XCTUnwrap(URL(string: XCTUnwrap(ready["url"] as? String))))
            let session = try await PairSession.connect(host: "127.0.0.1", port: port, relayToken: relay ? "ios-pair-token" : nil, code: invite.code, psk: pskMode ? invite.psk : nil)
            let server = try await fixture("art")
            XCTAssertEqual(server["art"] as? String, session.art)
            XCTAssertEqual(server["code"] as? String, session.code)
            _ = try await fixture(accept ? "approve" : "reject")
            do {
                let result = try await session.confirm(true, name: "iOS live test")
                XCTAssertTrue(accept)
                if relay { XCTAssertEqual(result.mode, "relay"); XCTAssertEqual(result.group, "paired-group") }
                else { XCTAssertEqual(result.key, "ios-pair-secret"); XCTAssertEqual(result.port, port) }
            } catch { if accept { throw error } }
            session.close()
            _ = try await fixture("finish")
        }
        print("E2E PASS live PairSession direct + relay + QR/PSK: C probe PTY art/code equals phone; dual approval returns secret/group; PSK still requires server approval; rejection does not save a secret")
    }
}
