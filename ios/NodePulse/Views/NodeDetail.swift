import SwiftUI
import Charts

struct NodeDetail: View {
    @Environment(\.pulseTheme) private var theme
    var store: MonitorStore
    var nodeKey: String
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
        ResourceHistoryChart(history: item.history)
    }
}

struct HistoryChartPointID: Hashable {
    var seq: UInt32?
    var date: Date
}
extension HistorySample {
    var chartID: HistoryChartPointID { HistoryChartPointID(seq: seq, date: date) }
}

struct HistoryChartClock {
    static let duration: TimeInterval = 120
    private var offset: TimeInterval?
    private var lastSample: Date?
    mutating func observe(_ latest: Date?, now: Date) {
        guard let latest else { return }
        let desired = latest.timeIntervalSince(now) - 1
        if offset == nil || latest < (lastSample ?? latest) || abs(desired - (offset ?? desired)) > 10 {
            offset = desired
        }
        lastSample = latest
    }
    func end(at now: Date) -> Date { now.addingTimeInterval(offset ?? -1) }
    static func marks(ending end: Date) -> [Date] {
        let start = ceil((end.timeIntervalSince1970 - duration) / 30) * 30
        return (0...4).map { Date(timeIntervalSince1970: start + Double($0) * 30) }.filter { $0 <= end }
    }
    static func showsLabel(at date: Date, ending end: Date) -> Bool {
        (12...108).contains(end.timeIntervalSince(date))
    }
}

struct HistoryChartBuffer {
    private(set) var samples: [HistorySample] = []
    mutating func observe(_ incoming: [HistorySample], ending end: Date) {
        guard !incoming.isEmpty else { samples = []; return }
        let ids = Set(incoming.map(\.chartID))
        let overlaps = samples.contains { ids.contains($0.chartID) }
        let first = incoming.map(\.date).min()!
        let sequences = Set(incoming.compactMap(\.seq))
        let prefix = overlaps ? samples.filter { sample in
            sample.date < first && (sample.seq.map { !sequences.contains($0) } ?? true)
        } : []
        var merged: [HistoryChartPointID: HistorySample] = [:]
        for sample in prefix + incoming { merged[sample.chartID] = sample }
        let ordered = merged.values.sorted {
            $0.date == $1.date ? ($0.seq ?? 0) < ($1.seq ?? 0) : $0.date < $1.date
        }
        let start = end.addingTimeInterval(-HistoryChartClock.duration)
        let firstVisible = ordered.firstIndex { $0.date >= start } ?? ordered.count
        samples = Array(ordered.dropFirst(max(0, firstVisible - 1)).suffix(241))
    }
}

struct HistoryChartScale {
    private(set) var upper: Double = 1000
    private var lowSince: Date?
    private var unitIndex: Int { min(4, max(0, Int(floor(log2(upper) / 10)))) }
    var ticks: [Double] {
        let unit = pow(1024, Double(unitIndex))
        let target = upper / unit / 4
        let magnitude = pow(10, floor(log10(target)))
        let step = ([1.0, 2, 5, 10].first { target / magnitude <= $0 } ?? 10) * magnitude * unit
        return (0...Int(floor(upper / step))).map { Double($0) * step }
    }
    func label(for value: Double) -> String {
        value == 0 ? "0B/s" : String(format: "%g%@/s", value / pow(1024, Double(unitIndex)), ["B", "K", "M", "G", "T"][unitIndex])
    }
    static func roundedCeiling(_ value: Double) -> Double {
        guard value.isFinite, value > 1000 else { return 1000 }
        let magnitude = pow(10, floor(log10(value)))
        let step = [1.0, 2, 5, 10].first { value / magnitude <= $0 } ?? 10
        return min(Double.greatestFiniteMagnitude, step * magnitude)
    }
    mutating func observe(peak: Double, now: Date) {
        let safe = peak.isFinite ? max(0, min(peak, Double.greatestFiniteMagnitude / 1.2)) : 0
        let desired = Self.roundedCeiling(safe * 1.15)
        if desired > upper { upper = desired; lowSince = nil }
        else if desired <= upper / 2 {
            if let lowSince, now.timeIntervalSince(lowSince) >= 30 { upper = desired; self.lowSince = nil }
            else if lowSince == nil { lowSince = now }
        } else { lowSince = nil }
    }
}

private struct ResourceHistoryChart: View {
    @Environment(\.pulseTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var history: [HistorySample]
    @State private var metric = "CPU"
    @State private var selection: Date?
    @State private var clock = HistoryChartClock()
    @State private var buffer = HistoryChartBuffer()
    @State private var scale = HistoryChartScale()
    private var network: Bool { metric == L10n.text("网络") }
    private var download: Color { theme == .default ? .blue : theme.ink }
    private var upload: Color {
        Color(uiColor: UIColor { traits in
            if theme == .grayscale { return UIColor(white: traits.userInterfaceStyle == .dark ? 0.48 : 0.55, alpha: 1) }
            return traits.userInterfaceStyle == .dark ? .systemOrange : UIColor(red: 0.76, green: 0.30, blue: 0.03, alpha: 1)
        })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text(L10n.text("资源趋势")).font(.headline); Spacer(); Text(L10n.text("最近 %@ 次采样", String(describing: history.count))).font(.caption).foregroundStyle(.secondary) }
            Picker(L10n.text("趋势指标"), selection: $metric) { ForEach(["CPU", L10n.text("内存"), L10n.text("网络")], id: \.self) { Text($0) } }.pickerStyle(.segmented)
            let sample = HistorySample.displayed(in: buffer.samples.isEmpty ? history : buffer.samples, at: selection)
            HStack {
                if network {
                    Text(sample.map { "↓ \(PulseFormat.rate($0.rxRate))" } ?? "—").foregroundStyle(download)
                    Text(sample.map { "↑ \(PulseFormat.rate($0.txRate))" } ?? "—").foregroundStyle(upload)
                } else {
                    Text(sample.map { String(format: "%.1f%%", metric == "CPU" ? $0.cpu : $0.memPercent) } ?? "—").foregroundStyle(theme.ink)
                }
                Spacer(minLength: 8)
                Text(sample.map { $0.date.formatted(date: .omitted, time: .standard) } ?? "—").foregroundStyle(.secondary)
            }.font(.caption.monospacedDigit()).lineLimit(1).minimumScaleFactor(0.7).frame(height: 24)
                .accessibilityIdentifier("chart-readout")
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { context in
                plot(ending: reduceMotion ? (history.last?.date ?? context.date) : clock.end(at: context.date))
            }
            if network {
                HStack(spacing: 20) {
                    legend(L10n.text("下行"), color: download, dashed: false)
                    legend(L10n.text("上行"), color: upload, dashed: true)
                }.font(.caption2)
            }
            Text(L10n.text("轻触或拖动图表，查看采样数值")).font(.caption2).foregroundStyle(.tertiary)
        }
        .onChange(of: history, initial: true) { _, points in
            let now = Date()
            clock.observe(points.last?.date, now: now)
            buffer.observe(points, ending: clock.end(at: now))
            scale.observe(peak: points.flatMap { [$0.rxRate, $0.txRate] }.filter(\.isFinite).max() ?? 0, now: now)
        }
        .transaction { $0.animation = nil }
    }
    private func legend(_ title: String, color: Color, dashed: Bool) -> some View {
        HStack(spacing: 5) {
            Path { path in path.move(to: .zero); path.addLine(to: CGPoint(x: 20, y: 0)) }
                .stroke(color, style: StrokeStyle(lineWidth: 2, dash: dashed ? [5, 3] : []))
                .frame(width: 20, height: 2)
            Text(title).foregroundStyle(color)
        }
    }
    private func plot(ending end: Date) -> some View {
        Chart(buffer.samples.isEmpty ? history : buffer.samples, id: \.chartID) { sample in
            if network {
                AreaMark(x: .value(L10n.text("时间"), sample.date), y: .value(L10n.text("速率"), sample.rxRate), stacking: .unstacked)
                    .foregroundStyle(LinearGradient(colors: [download.opacity(0.18), .clear], startPoint: .top, endPoint: .bottom)).interpolationMethod(.linear)
                LineMark(x: .value(L10n.text("时间"), sample.date), y: .value(L10n.text("速率"), sample.rxRate), series: .value(L10n.text("方向"), L10n.text("下行")))
                    .foregroundStyle(download).lineStyle(StrokeStyle(lineWidth: 2)).interpolationMethod(.linear)
                LineMark(x: .value(L10n.text("时间"), sample.date), y: .value(L10n.text("速率"), sample.txRate), series: .value(L10n.text("方向"), L10n.text("上行")))
                    .foregroundStyle(upload).lineStyle(StrokeStyle(lineWidth: 2, dash: [5, 3])).interpolationMethod(.linear)
            } else {
                AreaMark(x: .value(L10n.text("时间"), sample.date), y: .value(L10n.text("使用率"), metric == "CPU" ? sample.cpu : sample.memPercent))
                    .foregroundStyle(LinearGradient(colors: [theme.ink.opacity(0.28), theme.ink.opacity(0.01)], startPoint: .top, endPoint: .bottom)).interpolationMethod(.linear)
                LineMark(x: .value(L10n.text("时间"), sample.date), y: .value(L10n.text("使用率"), metric == "CPU" ? sample.cpu : sample.memPercent))
                    .foregroundStyle(theme.ink).interpolationMethod(.linear)
            }
            if let selection { RuleMark(x: .value(L10n.text("时间"), selection)).foregroundStyle(.secondary.opacity(0.4)) }
        }.chartLegend(.hidden)
            .chartXSelection(value: $selection)
            .chartXScale(domain: end.addingTimeInterval(-HistoryChartClock.duration)...end)
            .chartYScale(domain: network ? 0...scale.upper : 0...100)
            .chartPlotStyle { $0.clipped() }
            .chartXAxis { AxisMarks(values: HistoryChartClock.marks(ending: end)) { value in
                if let date = value.as(Date.self), HistoryChartClock.showsLabel(at: date, ending: end) {
                    AxisValueLabel {
                        Text(date.formatted(.dateTime.minute(.twoDigits).second(.twoDigits)))
                            .font(.caption2.monospacedDigit()).fixedSize()
                    }
                }
                AxisGridLine()
            } }
            .chartYAxis { AxisMarks(position: .leading, values: network ? scale.ticks : [0, 50, 100]) { value in
                AxisValueLabel {
                    Text(value.as(Double.self).map { network ? scale.label(for: $0) : String(format: "%.0f", $0) } ?? "")
                        .font(.caption2.monospacedDigit()).frame(width: 50, alignment: .trailing)
                }
                AxisGridLine()
            }
                AxisMarks(position: .trailing, values: network ? scale.ticks : [0, 50, 100]) { value in
                    AxisValueLabel {
                        Text(value.as(Double.self).map { network ? scale.label(for: $0) : String(format: "%.0f", $0) } ?? "")
                            .font(.caption2.monospacedDigit()).frame(width: 50, alignment: .leading).hidden()
                    }
                }
            }
            .frame(height: 170).accessibilityIdentifier("resource-chart")
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
