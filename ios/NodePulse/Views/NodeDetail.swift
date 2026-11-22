import SwiftUI
import Charts

struct NodeDetail: View {
    var store: MonitorStore
    var nodeKey: String
    @State private var metric = "CPU"
    @State private var selection: Date?
    @State private var copied = false
    @State private var deleting: NodeItem?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var item: NodeItem? { store.nodes.first { $0.key == nodeKey } }
    var body: some View {
        ScrollView {
            if let item {
                let s = item.snapshot
                VStack(spacing: 22) {
                    VStack(spacing: 14) {
                        OSBadge(os: s.os).scaleEffect(1.2).padding(8)
                        Text(s.name).font(.largeTitle.bold()).multilineTextAlignment(.center)
                        Text(s.os).font(.subheadline).foregroundStyle(.secondary)
                        if item.endToEnd { EndToEndBadge() }
                        HStack { OnlineStatus(online: item.online); Text(item.connectionLabel).font(.caption).foregroundStyle(.secondary) }
                        if let ip = s.ips.first { Button { copy(ip) } label: { Label(ip, systemImage: "doc.on.doc").font(.caption.monospaced()).padding(10).background(.mint.opacity(0.08), in: Capsule()) } }
                    }.frame(maxWidth: .infinity).padding(.vertical, 10)
                    HStack {
                        RingGauge(title: "CPU", value: s.cpuUsage, size: 86)
                        RingGauge(title: "内存", value: s.memPercent, size: 86)
                        RingGauge(title: "磁盘", value: s.diskTotal > 0 ? s.diskUsed / s.diskTotal * 100 : 0, size: 86)
                    }.pulsePanel()
                    NodeAdminSection(store: store, node: item)
                    chart(item).pulsePanel()
                    section("系统", symbol: "cpu") {
                        InfoRow(title: "操作系统", value: s.os)
                        InfoRow(title: "内核", value: s.kernel)
                        InfoRow(title: "架构", value: s.arch)
                        InfoRow(title: "CPU 型号", value: s.cpuModel)
                        InfoRow(title: "核心数", value: "\(s.cpuCores)")
                        InfoRow(title: "运行时长", value: PulseFormat.uptime(s.uptime))
                        InfoRow(title: "进程", value: "\(s.procs)")
                        InfoRow(title: "TCP 连接", value: "\(s.tcpConns)")
                        InfoRow(title: "温度", value: s.temp.map { String(format: "%.1f °C", $0) } ?? "—")
                    }
                    section("资源", symbol: "internaldrive") {
                        resource("内存", used: s.memUsed, total: s.memTotal)
                        resource("交换", used: s.swapUsed, total: s.swapTotal)
                        resource("磁盘", used: s.diskUsed, total: s.diskTotal)
                    }
                    section("网络", symbol: "network") {
                        ForEach(s.ips, id: \.self) { ip in
                            Button { copy(ip) } label: {
                                HStack { Text(ip).font(.subheadline.monospaced()).multilineTextAlignment(.leading); Spacer(); Image(systemName: "doc.on.doc") }.padding(.vertical, 7)
                            }
                        }
                        InfoRow(title: "累计接收", value: PulseFormat.bytes(s.netRx))
                        InfoRow(title: "累计发送", value: PulseFormat.bytes(s.netTx))
                    }
                }.padding(20).frame(maxWidth: 780).frame(maxWidth: .infinity)
                    .animation(reduceMotion ? nil : .smooth(duration: 0.6), value: s)
            } else { ContentUnavailableView("节点已移除", systemImage: "server.rack") }
        }.background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("节点详情").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if let item { Button("删除", systemImage: "trash", role: .destructive) { deleting = item } }
                }
            }
            .nodeDeletion(store: store, node: $deleting) { dismiss() }
            .overlay(alignment: .bottom) { if copied { Toast().padding(.bottom, 24).transition(.move(edge: .bottom).combined(with: .opacity)) } }
    }
    private func copy(_ text: String) {
        UIPasteboard.general.string = text
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        withAnimation { copied = true }
        Task { try? await Task.sleep(for: .seconds(1.6)); withAnimation { copied = false } }
    }
    private func section<Content: View>(_ title: String, symbol: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: symbol).font(.headline).padding(.bottom, 8)
            content()
        }.frame(maxWidth: .infinity, alignment: .leading).pulsePanel()
    }
    private func resource(_ title: String, used: Double, total: Double) -> some View {
        VStack(spacing: 8) {
            HStack { Text(title); Spacer(); Text("\(PulseFormat.bytes(used)) / \(PulseFormat.bytes(total))").foregroundStyle(.secondary).contentTransition(.numericText()) }.font(.caption)
            ProgressView(value: total > 0 ? min(used / total, 1) : 0).tint(PulseFormat.color(total > 0 ? used / total * 100 : 0))
        }.padding(.vertical, 8)
    }
    private func chart(_ item: NodeItem) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("资源趋势").font(.headline); Spacer(); Text("最近 \(item.history.count) 次采样").font(.caption).foregroundStyle(.secondary) }
            Picker("趋势指标", selection: $metric) { ForEach(["CPU", "内存", "网络"], id: \.self) { Text($0) } }.pickerStyle(.segmented)
            if let selection, let sample = item.history.min(by: { abs($0.date.timeIntervalSince(selection)) < abs($1.date.timeIntervalSince(selection)) }) {
                Text(metric == "网络" ? "↓ \(PulseFormat.rate(sample.rxRate))   ↑ \(PulseFormat.rate(sample.txRate))" : String(format: "%.1f%%", metric == "CPU" ? sample.cpu : sample.memPercent))
                    .font(.caption.monospacedDigit()).foregroundStyle(.mint)
            }
            Chart(Array(item.history.enumerated()), id: \.offset) { _, sample in
                if metric == "网络" {
                    AreaMark(x: .value("时间", sample.date), y: .value("速率", sample.rxRate), stacking: .unstacked)
                        .foregroundStyle(LinearGradient(colors: [.mint.opacity(0.18), .clear], startPoint: .top, endPoint: .bottom)).interpolationMethod(.catmullRom)
                    LineMark(x: .value("时间", sample.date), y: .value("速率", sample.rxRate), series: .value("方向", "下行"))
                        .foregroundStyle(by: .value("方向", "下行")).interpolationMethod(.catmullRom)
                    LineMark(x: .value("时间", sample.date), y: .value("速率", sample.txRate), series: .value("方向", "上行"))
                        .foregroundStyle(by: .value("方向", "上行")).interpolationMethod(.catmullRom)
                } else {
                    AreaMark(x: .value("时间", sample.date), y: .value("使用率", metric == "CPU" ? sample.cpu : sample.memPercent))
                        .foregroundStyle(LinearGradient(colors: [.mint.opacity(0.28), .mint.opacity(0.01)], startPoint: .top, endPoint: .bottom)).interpolationMethod(.catmullRom)
                    LineMark(x: .value("时间", sample.date), y: .value("使用率", metric == "CPU" ? sample.cpu : sample.memPercent))
                        .foregroundStyle(.mint).interpolationMethod(.catmullRom)
                }
                if let selection { RuleMark(x: .value("时间", selection)).foregroundStyle(.secondary.opacity(0.4)) }
            }.chartForegroundStyleScale(["下行": Color.mint, "上行": Color.orange])
                .chartLegend(metric == "网络" ? .visible : .hidden)
                .chartXSelection(value: $selection)
                .chartYScale(domain: metric == "网络" ? 0...max(1000, item.history.flatMap { [$0.rxRate, $0.txRate] }.max() ?? 1000) : 0...100)
                .chartXAxis { AxisMarks(values: .automatic(desiredCount: 3)) { _ in AxisValueLabel(format: .dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)); AxisGridLine() } }
                .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { _ in AxisValueLabel(); AxisGridLine() } }
                .frame(height: 170)
            Text("轻触或拖动图表，查看采样数值").font(.caption2).foregroundStyle(.tertiary)
        }
    }
}
