import XCTest
@testable import NodePulse

final class ThemeTests: XCTestCase {
    func testBundledThirdPartyNotices() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "ThirdPartyNotices", withExtension: "txt"))
        let notices = try String(contentsOf: url, encoding: .utf8)
        for component in ["SwiftTerm", "Monocypher", "Nayuki", "Permission is hereby granted", "BSD-2-Clause"] {
            XCTAssertTrue(notices.contains(component))
        }
    }
    func testPersistenceAndInvalidPreference() {
        let name = "Theme-\(UUID())", defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertEqual(PulseTheme.load(from: defaults), .default)
        defaults.set(PulseTheme.grayscale.rawValue, forKey: PulseTheme.storageKey)
        XCTAssertEqual(PulseTheme.load(from: UserDefaults(suiteName: name)!), .grayscale)
        defaults.set("invalid", forKey: PulseTheme.storageKey)
        XCTAssertEqual(PulseTheme.load(from: defaults), .default)
        defaults.set(PulseTheme.default.rawValue, forKey: PulseTheme.storageKey)
        XCTAssertEqual(PulseTheme.load(from: defaults), .default)
    }
}
