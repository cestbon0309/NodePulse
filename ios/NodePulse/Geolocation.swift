import Foundation
import Network
import Observation

struct GeoPlace: Codable, Equatable {
    var country: String
    var countryCode: String
    var region: String
    var city: String

    func formatted(language: String) -> String? {
        let country = country.isEmpty ? (countryCode.isEmpty ? "" : Locale(identifier: language).localizedString(forRegionCode: countryCode) ?? "") : country
        let detail = countryCode == "AU" && !city.isEmpty ? city : (region.isEmpty ? city : region)
        let parts = [country, detail].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let unique = parts.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        return unique.isEmpty ? nil : unique.joined(separator: "-")
    }
}

@MainActor @Observable final class GeolocationStore {
    struct Entry: Codable {
        var place: GeoPlace?
        var expires: Date
    }
    private var entries: [String: Entry]
    private var pending: [String: Task<GeoPlace?, Never>] = [:]
    private let defaults: UserDefaults
    private let fetch: (URLRequest) async throws -> (Data, URLResponse)
    private let now: () -> Date
    private static let cacheKey = "egressLocations.v1"

    init(defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init,
         fetch: @escaping (URLRequest) async throws -> (Data, URLResponse) = { try await URLSession.shared.data(for: $0) }) {
        self.defaults = defaults; self.now = now; self.fetch = fetch
        entries = defaults.data(forKey: Self.cacheKey).flatMap { try? JSONDecoder().decode([String: Entry].self, from: $0) } ?? [:]
    }

    static func language(_ locale: Locale = .current) -> String { locale.language.languageCode?.identifier == "zh" ? "zh-Hans" : "en" }

    static func publicIP(_ ip: String) -> String? {
        if let address = IPv4Address(ip) {
            let a = Array(address.rawValue)
            guard a[0] > 0, a[0] < 224, a[0] != 10, a[0] != 127,
                  !(a[0] == 100 && (a[1] & 192) == 64), !(a[0] == 169 && a[1] == 254),
                  !(a[0] == 172 && (a[1] & 240) == 16), !(a[0] == 192 && a[1] == 168),
                  !(a[0] == 192 && a[1] == 0 && (a[2] == 0 || a[2] == 2)),
                  !(a[0] == 198 && (a[1] == 18 || a[1] == 19 || (a[1] == 51 && a[2] == 100))),
                  !(a[0] == 203 && a[1] == 0 && a[2] == 113) else { return nil }
            return address.debugDescription
        }
        if let address = IPv6Address(ip), !ip.contains("%") {
            let a = Array(address.rawValue)
            guard a[0] & 224 == 32, !(a[0] == 32 && a[1] == 1 && a[2] == 13 && a[3] == 184) else { return nil }
            return address.debugDescription
        }
        return nil
    }

    func location(ip: String, language: String) async -> GeoPlace? {
        guard let ip = Self.publicIP(ip) else { return nil }
        let language = language == "zh-Hans" ? language : "en", key = "\(ip)|\(language)"
        if let entry = entries[key], entry.expires > now() { return entry.place }
        if let task = pending[key] { return await task.value }
        let task = Task { () -> GeoPlace? in
            do {
                var components = URLComponents(string: "https://ipwho.is/\(ip)")!
                components.queryItems = [URLQueryItem(name: "lang", value: language == "zh-Hans" ? "zh-CN" : "en")]
                var request = URLRequest(url: components.url!); request.timeoutInterval = 8
                let (data, response) = try await fetch(request)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200, data.count < 65536,
                      let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      object["success"] as? Bool == true, let responseIP = object["ip"] as? String,
                      Self.publicIP(responseIP) == ip else { return nil }
                let place = GeoPlace(country: object["country"] as? String ?? "", countryCode: object["country_code"] as? String ?? "",
                                     region: object["region"] as? String ?? "", city: object["city"] as? String ?? "")
                return place.formatted(language: language) == nil ? nil : place
            } catch { return nil }
        }
        pending[key] = task
        let place = await task.value
        pending[key] = nil
        entries[key] = Entry(place: place, expires: now().addingTimeInterval(place == nil ? 900 : 604800))
        if entries.count > 512 {
            let keep = entries.sorted { $0.value.expires > $1.value.expires }.prefix(512)
            entries = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
        defaults.set(try? JSONEncoder().encode(entries), forKey: Self.cacheKey)
        return place
    }
}
