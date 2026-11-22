import SwiftUI
import Charts

struct NodeDetail: View {
    @Environment(\.pulseTheme) private var theme
    var store: MonitorStore
    var nodeKey: String
    @State private var metric = "CPU"
    @State private var selection: Date?
    @State private var copied = false
    @State private var deleting: NodeItem?
    @State private var showingEgressIP = false
    @AppStorage("hideIPAddresses") private var hideIPAddresses = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var item: NodeItem? { store.nodes.first { $0.key == nodeKey } }
    var body: some View {
        ScrollView {
            if let item {
                let s = item.snapshot
                VStack(spacing: 22) {
                    VStack(spacing: 9) {
                        OSBadge(os: s.os).padding(4)
                        Text(s.name).font(.title.bold()).multilineTextAlignment(.center)
                        Text(s.os).font(.subheadline).foregroundStyle(.secondary)
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 7) {
                                connectionStatus(item)
                                NodeLocation(ip: s.egressIp, locations: store.locations, demo: store.demoMode)
                            }
                            VStack(spacing: 6) {
                                connectionStatus(item)
                                NodeLocation(ip: s.egressIp, locations: store.locations, demo: store.demoMode)
                            }
                        }
                        let addresses = DetailHeader.addresses(primary: s.ips.first, egress: s.egressIp)
                        if let primary = addresses.first {
                            let ip = showingEgressIP && addresses.count > 1 ? addresses[1] : primary
                            HStack(spacing: 8) {
                                Button { copy(ip) } label: {
                                    Label(PulseFormat.ip(ip, hidden: hideIPAddresses), systemImage: "doc.on.doc")
                                        .font(.caption.monospaced()).lineLimit(1).minimumScaleFactor(0.65)
                                }.accessibilityIdentifier("header-copy-ip")
                                if addresses.count > 1 {
                                    Button { showingEgressIP.toggle() } label: {
                                        Label(showingEgressIP ? L10n.text("出口") : L10n.text("本机 IP"), systemImage: "arrow.left.arrow.right")
                                            .font(.caption2).fixedSize()
                                    }.accessibilityHint(L10n.text("切换本机和出口 IP"))
                                }
                                Button(hideIPAddresses ? L10n.text("显示 IP") : L10n.text("隐藏 IP"), systemImage: hideIPAddresses ? "eye.slash" : "eye") { hideIPAddresses.toggle() }
                                    .labelStyle(.iconOnly).frame(width: 32, height: 44)
                            }.padding(.leading, 12).padding(.trailing, 4).background(theme.ink.opacity(0.08), in: Capsule())
                        }
                    }.frame(maxWidth: .infinity).padding(.vertical, 4)
                    HStack {
                        RingGauge(title: "CPU", value: s.cpuUsage, size: 86)
                        RingGauge(title: L10n.text("内存"), value: s.memPercent, size: 86)
                        RingGauge(title: L10n.text("磁盘"), value: s.diskTotal > 0 ? s.diskUsed / s.diskTotal * 100 : 0, size: 86)
                    }.pulsePanel()
                    NodeAdminSection(store: store, node: item)
                    chart(item).pulsePanel()
                    section(L10n.text("系统"), symbol: "cpu") {
                        InfoRow(title: L10n.text("操作系统"), value: s.os)
                        InfoRow(title: L10n.text("内核"), value: s.kernel)
                        InfoRow(title: L10n.text("架构"), value: s.arch)
                        InfoRow(title: L10n.text("CPU 型号"), value: s.cpuModel)
                        InfoRow(title: L10n.text("核心数"), value: "\(s.cpuCores)")
                        InfoRow(title: L10n.text("运行时长"), value: PulseFormat.uptime(s.uptime))
                        InfoRow(title: L10n.text("进程"), value: "\(s.procs)")
                        InfoRow(title: L10n.text("TCP 连接"), value: "\(s.tcpConns)")
                        InfoRow(title: L10n.text("温度"), value: s.temp.map { String(format: "%.1f °C", $0) } ?? "—")
                    }
                    section(L10n.text("资源"), symbol: "internaldrive") {
                        resource(L10n.text("内存"), used: s.memUsed, total: s.memTotal)
                        resource(L10n.text("交换"), used: s.swapUsed, total: s.swapTotal)
                        resource(L10n.text("磁盘"), used: s.diskUsed, total: s.diskTotal)
                    }
                    section(L10n.text("网络"), symbol: "network") {
                        ForEach(s.ips, id: \.self) { ip in
                            Button { copy(ip) } label: {
                                HStack { Text(PulseFormat.ip(ip, hidden: hideIPAddresses)).font(.subheadline.monospaced()).multilineTextAlignment(.leading); Spacer(); Image(systemName: "doc.on.doc") }.padding(.vertical, 7)
                            }
                        }
                        InfoRow(title: L10n.text("累计接收"), value: PulseFormat.bytes(s.netRx))
                        InfoRow(title: L10n.text("累计发送"), value: PulseFormat.bytes(s.netTx))
                    }
                }.padding(20).frame(maxWidth: 780).frame(maxWidth: .infinity)
                    .animation(reduceMotion ? nil : .smooth(duration: 0.6), value: s)
            } else { ContentUnavailableView(L10n.text("节点已移除"), systemImage: "server.rack") }
        }.background(theme.background)
            .navigationTitle(L10n.text("节点详情")).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if let item { Button(L10n.text("删除"), systemImage: "trash", role: .destructive) { deleting = item } }
                }
            }
            .nodeDeletion(store: store, node: $deleting) { dismiss() }
            .overlay(alignment: .bottom) { if copied { Toast().padding(.bottom, 24).transition(.move(edge: .bottom).combined(with: .opacity)) } }
    }
    private func connectionStatus(_ item: NodeItem) -> some View {
        HStack(spacing: 6) {
            OnlineStatus(online: item.online)
            Text("·").foregroundStyle(.tertiary)
            Text(item.connectionLabel).font(.caption).foregroundStyle(.secondary)
            if item.usesEndToEndEncryption { EndToEndBadge() }
        }.fixedSize(horizontal: true, vertical: false)
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
            ProgressView(value: total > 0 ? min(used / total, 1) : 0).tint(theme.gauge(total > 0 ? used / total * 100 : 0))
        }.padding(.vertical, 8)
    }
    private func chart(_ item: NodeItem) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text(L10n.text("资源趋势")).font(.headline); Spacer(); Text(L10n.text("最近 %@ 次采样", String(describing: item.history.count))).font(.caption).foregroundStyle(.secondary) }
            Picker(L10n.text("趋势指标"), selection: $metric) { ForEach(["CPU", L10n.text("内存"), L10n.text("网络")], id: \.self) { Text($0) } }.pickerStyle(.segmented)
            let sample = HistorySample.displayed(in: item.history, at: selection)
            HStack {
                Text(sample.map { metric == L10n.text("网络") ? "↓ \(PulseFormat.rate($0.rxRate))   ↑ \(PulseFormat.rate($0.txRate))" : String(format: "%.1f%%", metric == "CPU" ? $0.cpu : $0.memPercent) } ?? "—")
                    .foregroundStyle(theme.ink).contentTransition(.numericText())
                Spacer(minLength: 8)
                Text(sample.map { $0.date.formatted(date: .omitted, time: .standard) } ?? "—").foregroundStyle(.secondary)
            }.font(.caption.monospacedDigit()).lineLimit(1).minimumScaleFactor(0.7).frame(height: 24)
                .accessibilityIdentifier("chart-readout")
            Chart(Array(item.history.enumerated()), id: \.offset) { _, sample in
                if metric == L10n.text("网络") {
                    AreaMark(x: .value(L10n.text("时间"), sample.date), y: .value(L10n.text("速率"), sample.rxRate), stacking: .unstacked)
                        .foregroundStyle(LinearGradient(colors: [theme.ink.opacity(0.18), .clear], startPoint: .top, endPoint: .bottom)).interpolationMethod(.catmullRom)
                    LineMark(x: .value(L10n.text("时间"), sample.date), y: .value(L10n.text("速率"), sample.rxRate), series: .value(L10n.text("方向"), L10n.text("下行")))
                        .foregroundStyle(by: .value(L10n.text("方向"), L10n.text("下行"))).interpolationMethod(.catmullRom)
                    LineMark(x: .value(L10n.text("时间"), sample.date), y: .value(L10n.text("速率"), sample.txRate), series: .value(L10n.text("方向"), L10n.text("上行")))
                        .foregroundStyle(by: .value(L10n.text("方向"), L10n.text("上行"))).interpolationMethod(.catmullRom)
                } else {
                    AreaMark(x: .value(L10n.text("时间"), sample.date), y: .value(L10n.text("使用率"), metric == "CPU" ? sample.cpu : sample.memPercent))
                        .foregroundStyle(LinearGradient(colors: [theme.ink.opacity(0.28), theme.ink.opacity(0.01)], startPoint: .top, endPoint: .bottom)).interpolationMethod(.catmullRom)
                    LineMark(x: .value(L10n.text("时间"), sample.date), y: .value(L10n.text("使用率"), metric == "CPU" ? sample.cpu : sample.memPercent))
                        .foregroundStyle(theme.ink).interpolationMethod(.catmullRom)
                }
                if let selection { RuleMark(x: .value(L10n.text("时间"), selection)).foregroundStyle(.secondary.opacity(0.4)) }
            }.chartForegroundStyleScale([L10n.text("下行"): theme.ink, L10n.text("上行"): theme.secondaryInk])
                .chartLegend(metric == L10n.text("网络") ? .visible : .hidden)
                .chartXSelection(value: $selection)
                .chartYScale(domain: metric == L10n.text("网络") ? 0...max(1000, item.history.flatMap { [$0.rxRate, $0.txRate] }.max() ?? 1000) : 0...100)
                .chartXAxis { AxisMarks(values: .automatic(desiredCount: 3)) { _ in AxisValueLabel(format: .dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)); AxisGridLine() } }
                .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { _ in AxisValueLabel(); AxisGridLine() } }
                .frame(height: 170).accessibilityIdentifier("resource-chart")
            Text(L10n.text("轻触或拖动图表，查看采样数值")).font(.caption2).foregroundStyle(.tertiary)
        }
    }
}

@MainActor enum DetailHeader {
    static func addresses(primary: String?, egress: String?) -> [String] {
        var result = primary.map { $0.isEmpty ? [] : [$0] } ?? []
        if let egress, GeolocationStore.publicIP(egress) != nil,
           !result.contains(where: { $0.caseInsensitiveCompare(egress) == .orderedSame }) {
            result.append(egress)
        }
        return result
    }
}
