import SwiftUI

struct CompactNodeCard: View {
    @Environment(\.pulseTheme) private var theme
    @ScaledMetric(relativeTo: .subheadline) private var titleHeight = 20
    @ScaledMetric(relativeTo: .caption2) private var osHeight = 14
    @ScaledMetric(relativeTo: .caption) private var locationHeight = 16
    var item: NodeItem
    var locations: GeolocationStore
    var demo = false
    private var snapshot: NodeSnapshot { item.snapshot }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(snapshot.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Spacer(minLength: 0)
                    if item.usesEndToEndEncryption {
                        Image(systemName: "lock.shield.fill")
                            .font(.system(size: 11, weight: .medium)).foregroundStyle(theme.ink)
                            .accessibilityLabel(L10n.text("端到端加密"))
                    }
                    Circle().fill(item.online ? theme.accent : .gray).frame(width: 6, height: 6)
                        .accessibilityLabel(item.online ? L10n.text("在线") : L10n.text("离线"))
                }.frame(height: titleHeight)
                Text(snapshot.os).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    .frame(height: osHeight, alignment: .leading)
            }
            ZStack(alignment: .leading) {
                NodeLocation(ip: snapshot.egressIp, locations: locations, demo: demo)
            }.lineLimit(1).minimumScaleFactor(0.8)
                .frame(height: locationHeight, alignment: .leading)
            VStack(spacing: 9) {
                metric("CPU", value: snapshot.cpuUsage)
                metric(L10n.text("内存"), value: snapshot.memPercent)
                metric(L10n.text("磁盘"), value: snapshot.diskTotal > 0 ? snapshot.diskUsed / snapshot.diskTotal * 100 : 0)
            }
            HStack(spacing: 4) {
                Text("↑\(PulseFormat.compactRate(snapshot.netTxRate))").frame(maxWidth: .infinity, alignment: .leading)
                Text("↓\(PulseFormat.compactRate(snapshot.netRxRate))").frame(maxWidth: .infinity, alignment: .trailing)
            }.font(.system(size: 10, weight: .medium, design: .rounded)).monospacedDigit()
                .foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.7)
                .contentTransition(.numericText())
        }.padding(14).foregroundStyle(.primary)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(theme.surface, in: RoundedRectangle(cornerRadius: 22))
            .saturation(item.online ? 1 : 0).opacity(item.online ? 1 : 0.65)
    }
    private func metric(_ title: String, value: Double) -> some View {
        VStack(spacing: 4) {
            HStack {
                Text(title).foregroundStyle(.secondary)
                Spacer(minLength: 2)
                Text("\(value, specifier: "%.0f")%").monospacedDigit().contentTransition(.numericText())
            }.font(.caption2)
            GeometryReader { geometry in
                Capsule().fill(theme.gauge(value).opacity(0.1))
                    .overlay(alignment: .leading) {
                        Capsule().fill(theme.gauge(value).gradient)
                            .frame(width: geometry.size.width * min(max(value / 100, 0), 1))
                    }
            }.frame(height: 3)
        }.accessibilityElement(children: .ignore).accessibilityLabel("\(title) \(Int(value))%")
    }
}
