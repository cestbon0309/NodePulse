import XCTest
@testable import NodePulse

@MainActor final class GeolocationTests: XCTestCase {
    func testLocationFormatting() {
        XCTAssertEqual(GeoPlace(country: "中国", countryCode: "CN", region: "湖南", city: "长沙").formatted(language: "zh-Hans"), "中国-湖南")
        XCTAssertEqual(GeoPlace(country: "Australia", countryCode: "AU", region: "New South Wales", city: "Sydney").formatted(language: "en"), "Australia-Sydney")
        XCTAssertEqual(GeoPlace(country: "Japan", countryCode: "JP", region: "", city: "Tokyo").formatted(language: "en"), "Japan-Tokyo")
        XCTAssertEqual(GeoPlace(country: "Singapore", countryCode: "SG", region: "Singapore", city: "Singapore").formatted(language: "en"), "Singapore")
        XCTAssertNil(GeoPlace(country: "", countryCode: "", region: "", city: "").formatted(language: "en"))
    }

    func testPublicIPValidation() {
        for ip in ["1.1.1.1", "8.8.8.8", "2606:4700:4700::1111"] { XCTAssertNotNil(GeolocationStore.publicIP(ip)) }
        for ip in ["", "garbage", "example.com", "1.1.1.1/path", "10.0.0.1", "127.0.0.1", "169.254.1.1", "100.64.1.1", "192.168.0.1", "203.0.113.1", "::1", "fe80::1", "2001:db8::1", "::ffff:127.0.0.1"] {
            XCTAssertNil(GeolocationStore.publicIP(ip), ip)
        }
    }

    func testPersistentCacheLanguageKeysAndExpiry() async throws {
        let suite = "Locations-\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var now = Date(), calls = 0
        let fetch: (URLRequest) async throws -> (Data, URLResponse) = { request in
            calls += 1
            XCTAssertEqual(request.url?.scheme, "https")
            let chinese = request.url!.query!.contains("zh-CN")
            let data = try JSONSerialization.data(withJSONObject: ["success": true, "ip": "1.1.1.1", "country": chinese ? "中国" : "China", "country_code": "CN", "region": chinese ? "湖南" : "Hunan", "city": ""])
            return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let store = GeolocationStore(defaults: defaults, now: { now }, fetch: fetch)
        let english = await store.location(ip: "1.1.1.1", language: "en")
        XCTAssertEqual(english?.formatted(language: "en"), "China-Hunan")
        _ = await store.location(ip: "1.1.1.1", language: "en"); XCTAssertEqual(calls, 1)
        let restored = GeolocationStore(defaults: defaults, now: { now }, fetch: fetch)
        _ = await restored.location(ip: "1.1.1.1", language: "en"); XCTAssertEqual(calls, 1)
        let chinese = await restored.location(ip: "1.1.1.1", language: "zh-Hans")
        XCTAssertEqual(chinese?.formatted(language: "zh-Hans"), "中国-湖南"); XCTAssertEqual(calls, 2)
        now = now.addingTimeInterval(8 * 86400)
        _ = await restored.location(ip: "1.1.1.1", language: "en"); XCTAssertEqual(calls, 3)
    }

    func testFailureCacheAndConcurrentRequests() async {
        let suite = "Locations-\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var calls = 0, now = Date()
        let store = GeolocationStore(defaults: defaults, now: { now }) { request in
            calls += 1
            try await Task.sleep(for: .milliseconds(30))
            return (Data("{}".utf8), HTTPURLResponse(url: request.url!, statusCode: 429, httpVersion: nil, headerFields: nil)!)
        }
        async let a = store.location(ip: "1.1.1.1", language: "en")
        async let b = store.location(ip: "1.1.1.1", language: "en")
        let result = await (a, b)
        XCTAssertNil(result.0); XCTAssertNil(result.1); XCTAssertEqual(calls, 1)
        _ = await store.location(ip: "1.1.1.1", language: "en"); XCTAssertEqual(calls, 1)
        now = now.addingTimeInterval(901)
        _ = await store.location(ip: "1.1.1.1", language: "en"); XCTAssertEqual(calls, 2)
        _ = await store.location(ip: "192.168.1.1", language: "en"); XCTAssertEqual(calls, 2)
    }

    func testMalformedEmptyAndMismatchedResponses() async throws {
        let suite = "Locations-\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        for body in ["", "not JSON", "{}", "{\"success\":false}", "{\"success\":true,\"ip\":\"8.8.8.8\",\"country\":\"China\"}", "{\"success\":true,\"ip\":\"1.1.1.1\"}"] {
            defaults.removePersistentDomain(forName: suite)
            let store = GeolocationStore(defaults: defaults) { request in
                (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            let value = await store.location(ip: "1.1.1.1", language: "en")
            XCTAssertNil(value, body)
        }
        let store = GeolocationStore(defaults: defaults) { _ in throw URLError(.notConnectedToInternet) }
        let value = await store.location(ip: "8.8.8.8", language: "en")
        XCTAssertNil(value)
    }

    func testEgressSnapshotCompatibility() throws {
        let nodes = try ProbeResponse.decode(Data("{\"ok\":true,\"nodes\":[{\"id\":\"new\",\"egress_ip\":\"1.1.1.1\"},{\"id\":\"old\"}]}".utf8))
        XCTAssertEqual(nodes[0].egressIp, "1.1.1.1"); XCTAssertNil(nodes[1].egressIp)
    }

    func testCatalogContainsBothLanguagesAndFormatArguments() throws {
        for language in ["en", "zh-Hans"] {
            let url = try XCTUnwrap(Bundle.main.url(forResource: language, withExtension: "lproj"))
            let bundle = try XCTUnwrap(Bundle(url: url))
            XCTAssertEqual(bundle.localizedString(forKey: "直连", value: nil, table: nil), language == "en" ? "Direct" : "直连")
            let format = bundle.localizedString(forKey: "经由 %@", value: nil, table: nil)
            XCTAssertEqual(String(format: format, "Gateway"), language == "en" ? "Via Gateway" : "经由 Gateway")
        }
        XCTAssertEqual(GeolocationStore.language(Locale(identifier: "zh_Hans_CN")), "zh-Hans")
        XCTAssertEqual(GeolocationStore.language(Locale(identifier: "en_AU")), "en")
    }
}
