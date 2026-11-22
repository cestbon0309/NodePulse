import SwiftUI
import Charts

enum PulseFormat {
    static func bytes(_ value: Double) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        formatter.allowsNonnumericFormatting = false
        return formatter.string(fromByteCount: Int64(max(0, min(value, Double(Int64.max - 1024)))))
    }
    static func rate(_ value: Double) -> String { bytes(value) + "/秒" }
    static func uptime(_ seconds: Double) -> String {
        let hours = Int(max(0, seconds) / 3600)
        return hours >= 24 ? "\(hours / 24)天 \(hours % 24)小时" : "\(hours)小时 \(Int(max(0, seconds) / 60) % 60)分钟"
    }
    static func ago(_ timestamp: Double?) -> String { "\(max(0, Int((Date().timeIntervalSince1970 - (timestamp ?? Date().timeIntervalSince1970)) / 60))) 分钟前" }
    static func color(_ value: Double) -> Color { value < 60 ? .mint : value < 85 ? .orange : .red }
}

extension View {
    func pulsePanel() -> some View {
        padding(20).background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 26))
    }
    @ViewBuilder func zoomSource(_ id: String, namespace: Namespace.ID) -> some View {
        if #available(iOS 18, *) { matchedTransitionSource(id: id, in: namespace) } else { self }
    }
    @ViewBuilder func zoomDestination(_ id: String, namespace: Namespace.ID) -> some View {
        if #available(iOS 18, *) { navigationTransition(.zoom(sourceID: id, in: namespace)) } else { self }
    }
}

struct RingGauge: View {
    var title: String
    var value: Double
    var size: CGFloat = 72
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle().stroke(PulseFormat.color(value).opacity(0.12), lineWidth: 7)
                Circle().trim(from: 0, to: max(0, min(value / 100, 1)))
                    .stroke(PulseFormat.color(value).gradient, style: StrokeStyle(lineWidth: 7, lineCap: .round))
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
    var history: [HistorySample]
    var body: some View {
        Chart(Array(history.enumerated()), id: \.offset) { _, sample in
            AreaMark(x: .value("时间", sample.date), y: .value("CPU", sample.cpu))
                .foregroundStyle(LinearGradient(colors: [.mint.opacity(0.22), .mint.opacity(0.01)], startPoint: .top, endPoint: .bottom))
                .interpolationMethod(.catmullRom)
            LineMark(x: .value("时间", sample.date), y: .value("CPU", sample.cpu))
                .foregroundStyle(.mint).lineStyle(StrokeStyle(lineWidth: 2)).interpolationMethod(.catmullRom)
        }.chartYScale(domain: 0...100).chartXAxis(.hidden).chartYAxis(.hidden)
            .frame(height: 38).accessibilityLabel("CPU 使用率趋势")
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
        Label("已复制", systemImage: "checkmark.circle.fill").font(.subheadline.weight(.medium))
            .padding(.horizontal, 24).padding(.vertical, 13).background(.regularMaterial, in: Capsule()).shadow(radius: 12, y: 4)
    }
}

struct OSBadge: View {
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
        Image(systemName: symbol).font(.title3).foregroundStyle(.mint)
            .frame(width: 44, height: 44).background(.mint.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
    }
}

struct OnlineStatus: View {
    var online: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(online ? .mint : .gray).frame(width: 7, height: 7)
                .overlay { if online { Circle().stroke(.mint.opacity(0.35)).scaleEffect(pulse ? 1.9 : 1).opacity(pulse ? 0 : 1) } }
            Text(online ? "在线" : "离线").font(.caption)
        }.foregroundStyle(online ? .mint : .secondary)
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
