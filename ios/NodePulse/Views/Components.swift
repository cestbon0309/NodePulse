import SwiftUI
import Charts

struct EndToEndBadge: View {
    @Environment(\.pulseTheme) private var theme
    var body: some View {
        Label(L10n.text("端到端"), systemImage: "lock.shield")
            .font(.system(size: 10, weight: .medium)).fixedSize()
            .padding(.horizontal, 7).padding(.vertical, 4)
            .foregroundStyle(theme.ink)
            .background(theme.ink.opacity(0.1), in: Capsule())
    }
}
enum PulseFormat {
    static func ip(_ address: String, hidden: Bool) -> String {
        guard hidden, !address.isEmpty else { return address }
        return "•.•.•.•"
    }
    static func bytes(_ value: Double) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        formatter.allowsNonnumericFormatting = false
        return formatter.string(fromByteCount: Int64(max(0, min(value, Double(Int64.max - 1024)))))
    }
    static func rate(_ value: Double) -> String { bytes(value) + L10n.text("/秒") }
    static func compactRate(_ value: Double) -> String {
        var amount = value.isFinite ? max(0, value) : 0
        let units = ["B", "K", "M", "G", "T"]
        var unit = 0
        while amount >= 1024 && unit < units.count - 1 { amount /= 1024; unit += 1 }
        return String(format: amount >= 10 || unit == 0 ? "%.0f%@/s" : "%.1f%@/s", amount, units[unit])
    }
    static func uptime(_ seconds: Double) -> String {
        let hours = Int(max(0, seconds) / 3600)
        return hours >= 24 ? L10n.text("%@天 %@小时", String(describing: hours / 24), String(describing: hours % 24)) : L10n.text("%@小时 %@分钟", String(describing: hours), String(describing: Int(max(0, seconds) / 60) % 60))
    }
    static func ago(_ timestamp: Double?) -> String { L10n.text("%@ 分钟前", String(describing: max(0, Int((Date().timeIntervalSince1970 - (timestamp ?? Date().timeIntervalSince1970)) / 60)))) }
}

extension View {
    func pulsePanel() -> some View {
        modifier(PulsePanel())
    }
    @ViewBuilder func zoomSource(_ id: String, namespace: Namespace.ID) -> some View {
        if #available(iOS 18, *) { matchedTransitionSource(id: id, in: namespace) } else { self }
    }
    @ViewBuilder func zoomDestination(_ id: String, namespace: Namespace.ID) -> some View {
        if #available(iOS 18, *) { navigationTransition(.zoom(sourceID: id, in: namespace)) } else { self }
    }
}

struct RingGauge: View {
    @Environment(\.pulseTheme) private var theme
    var title: String
    var value: Double
    var size: CGFloat = 72
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle().stroke(theme.gauge(value).opacity(0.12), lineWidth: 7)
                Circle().trim(from: 0, to: max(0, min(value / 100, 1)))
                    .stroke(theme.gauge(value).gradient, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text("\(value, specifier: "%.0f")").font(.system(size: size * 0.26, weight: .semibold, design: .rounded))
                    .contentTransition(.numericText())
            }.frame(width: size, height: size)
            Text(title).font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity)
            .animation(reduceMotion ? nil : .spring(duration: 0.7), value: value)
            .accessibilityElement(children: .ignore).accessibilityLabel("\(title) \(Int(value))%")
    }
}

struct Sparkline: View {
    @Environment(\.pulseTheme) private var theme
    var history: [HistorySample]
    var body: some View {
        Chart(Array(history.enumerated()), id: \.offset) { _, sample in
            AreaMark(x: .value(L10n.text("时间"), sample.date), y: .value("CPU", sample.cpu))
                .foregroundStyle(LinearGradient(colors: [theme.ink.opacity(0.22), theme.ink.opacity(0.01)], startPoint: .top, endPoint: .bottom))
                .interpolationMethod(.catmullRom)
            LineMark(x: .value(L10n.text("时间"), sample.date), y: .value("CPU", sample.cpu))
                .foregroundStyle(theme.ink).lineStyle(StrokeStyle(lineWidth: 2)).interpolationMethod(.catmullRom)
        }.chartYScale(domain: 0...100).chartXAxis(.hidden).chartYAxis(.hidden)
            .frame(height: 38).accessibilityLabel(L10n.text("CPU 使用率趋势"))
    }
}

struct StatTile: View {
    var title: String
    var value: String
    var symbol: String
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(title, systemImage: symbol).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(.title3, design: .rounded, weight: .semibold))
                .contentTransition(.numericText()).minimumScaleFactor(0.7).lineLimit(1)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct InfoRow: View {
    var title: String
    var value: String
    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            Text(title).foregroundStyle(.secondary).frame(width: 76, alignment: .leading)
            Text(value.isEmpty ? "—" : value).frame(maxWidth: .infinity, alignment: .trailing).textSelection(.enabled)
        }.font(.subheadline).padding(.vertical, 6)
    }
}

struct Toast: View {
    var body: some View {
        Label(L10n.text("已复制"), systemImage: "checkmark.circle.fill").font(.subheadline.weight(.medium))
            .padding(.horizontal, 24).padding(.vertical, 13).background(.regularMaterial, in: Capsule()).shadow(radius: 12, y: 4)
    }
}

struct OSBadge: View {
    @Environment(\.pulseTheme) private var theme
    var os: String
    private var symbol: String {
        let text = os.lowercased()
        if text.contains("openwrt") { return "wifi.router.fill" }
        if text.contains("ubuntu") { return "circle.hexagongrid.fill" }
        if text.contains("debian") { return "hurricane" }
        if text.contains("alpine") { return "mountain.2.fill" }
        if text.contains("centos") { return "square.stack.3d.up.fill" }
        return "server.rack"
    }
    var body: some View {
        Image(systemName: symbol).font(.title3).foregroundStyle(theme.ink)
            .frame(width: 44, height: 44).background(theme.ink.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
    }
}

struct OnlineStatus: View {
    @Environment(\.pulseTheme) private var theme
    var online: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(online ? theme.accent : .gray).frame(width: 7, height: 7)
                .overlay { if online { Circle().stroke(theme.accent.opacity(0.35)).scaleEffect(pulse ? 1.9 : 1).opacity(pulse ? 0 : 1) } }
            Text(online ? L10n.text("在线") : L10n.text("离线")).font(.caption)
        }.foregroundStyle(online ? theme.accent : .secondary)
            .onAppear { if online && !reduceMotion { withAnimation(.easeOut(duration: 1.8).repeatForever(autoreverses: false)) { pulse = true } } }
    }
}

struct PressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .animation(.spring(duration: 0.25), value: configuration.isPressed)
    }
}
