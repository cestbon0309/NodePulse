import XCTest
@testable import NodePulse

final class ThemeTests: XCTestCase {
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
