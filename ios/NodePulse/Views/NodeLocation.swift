import SwiftUI

struct NodeLocation: View {
    var ip: String?
    var locations: GeolocationStore
    var showIP = false
    var demo = false
    @State private var place: GeoPlace?
    @Environment(\.locale) private var locale
    @AppStorage("hideIPAddresses") private var hideIPAddresses = false
    private var language: String { GeolocationStore.language(locale) }

    var body: some View {
        if let ip, GeolocationStore.publicIP(ip) != nil {
            VStack(spacing: 5) {
                Label(place?.formatted(language: language) ?? L10n.text("位置未知"), systemImage: "mappin.and.ellipse")
                    .font(.caption).foregroundStyle(.secondary)
                if showIP {
                    Button { UIPasteboard.general.string = ip } label: {
                        Label(PulseFormat.ip(ip, hidden: hideIPAddresses), systemImage: "doc.on.doc")
                            .font(.caption.monospaced())
                    }.accessibilityHint(L10n.text("复制出口 IP"))
                }
            }.task(id: "\(ip)|\(language)") {
                if demo {
                    place = GeoPlace(country: L10n.text("中国"), countryCode: "CN", region: L10n.text("湖南"), city: L10n.text("长沙"))
                } else { place = await locations.location(ip: ip, language: language) }
            }
        }
    }
}
