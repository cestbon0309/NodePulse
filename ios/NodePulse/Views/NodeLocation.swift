import SwiftUI

struct NodeLocation: View {
    var ip: String?
    var locations: GeolocationStore
    var demo = false
    @State private var place: GeoPlace?
    @Environment(\.locale) private var locale
    private var language: String { GeolocationStore.language(locale) }

    var body: some View {
        if let ip, GeolocationStore.publicIP(ip) != nil {
            VStack(spacing: 5) {
                Label(place?.formatted(language: language) ?? L10n.text("位置未知"), systemImage: "mappin.and.ellipse")
                    .font(.caption).foregroundStyle(.secondary)
            }.task(id: "\(ip)|\(language)") {
                if demo {
                    place = GeoPlace(country: L10n.text("中国"), countryCode: "CN", region: L10n.text("湖南"), city: L10n.text("长沙"))
                } else { place = await locations.location(ip: ip, language: language) }
            }
        }
    }
}
