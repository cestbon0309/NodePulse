import SwiftUI

struct ContentView: View {
    @Environment(\.pulseTheme) private var theme
    @Bindable var store: MonitorStore
    @State private var filter = L10n.text("全部")
    @State private var search = ""
    @State private var sheet: DashboardSheet?
    @State private var errorDismissed = false
    @State private var deleting: NodeItem?
    @AppStorage("classicLayout") private var classicLayout = false
    @Namespace private var zoom
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    enum DashboardSheet: String, Identifiable { case add, settings, endpoints; var id: String { rawValue } }
    private var visible: [NodeItem] {
        store.nodes.filter { item in
            (filter == L10n.text("全部") || (filter == L10n.text("在线") ? item.online : !item.online)) &&
            (search.isEmpty || ([item.snapshot.name, item.snapshot.os] + item.snapshot.ips).joined(separator: " ").localizedCaseInsensitiveContains(search))
        }
    }
    private var failures: Int { store.endpoints.filter { store.statuses[$0.id]?.error != nil }.count }
    private var columns: [GridItem] {
        if classicLayout {
            return sizeClass == .compact ? Array(repeating: GridItem(.flexible(), spacing: 12), count: 2) : [GridItem(.adaptive(minimum: 180), spacing: 16)]
        }
        return sizeClass == .compact ? [GridItem(.flexible())] : [GridItem(.adaptive(minimum: 310), spacing: 20)]
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    if failures > 0 && !errorDismissed {
                        HStack {
                            Button { sheet = .endpoints } label: { Label(L10n.text("%@ 个接入点连接失败", String(describing: failures)), systemImage: "exclamationmark.triangle.fill") }
                            Spacer()
                            Button { errorDismissed = true } label: { Image(systemName: "xmark") }.accessibilityLabel(L10n.text("关闭提示"))
                        }.font(.caption.weight(.medium)).foregroundStyle(theme.warning).padding(14).background(theme.warning.opacity(0.1), in: Capsule())
                    }
                    if store.endpoints.isEmpty && !store.demoMode {
                        emptyState
                    } else {
                        SummaryHeader(nodes: store.nodes)
                        Picker(L10n.text("节点筛选"), selection: $filter) { ForEach([L10n.text("全部"), L10n.text("在线"), L10n.text("离线")], id: \.self) { Text($0) } }.pickerStyle(.segmented)
                        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion || classicLayout || scenePhase != .active)) { context in
                            LazyVGrid(columns: columns, spacing: classicLayout ? 12 : 18) {
                                ForEach(Array(visible.enumerated()), id: \.element.key) { index, item in
                                    NavigationLink {
                                        NodeDetail(store: store, nodeKey: item.key).zoomDestination(item.key, namespace: zoom)
                                    } label: {
                                        Group {
                                            if classicLayout { CompactNodeCard(item: item, locations: store.locations, demo: store.demoMode) }
                                            else { NodeCard(item: item, index: index, locations: store.locations, demo: store.demoMode) }
                                        }.zoomSource(item.key, namespace: zoom)
                                    }
                                        .buttonStyle(PressStyle())
                                        .contextMenu {
                                            Button(L10n.text("复制 IP"), systemImage: "doc.on.doc") { UIPasteboard.general.string = item.snapshot.ips.joined(separator: "\n") }
                                            NavigationLink { NodeDetail(store: store, nodeKey: item.key) } label: { Label(L10n.text("查看详情"), systemImage: "info.circle") }
                                            Button(L10n.text("删除"), systemImage: "trash", role: .destructive) { deleting = item }
                                        }
                                }
                            }.environment(\.historyChartDate, context.date)
                        }
                        if visible.isEmpty { ContentUnavailableView(L10n.text("没有匹配的节点"), systemImage: "magnifyingglass", description: Text(L10n.text("试试其他名称、IP 或系统"))) }
                    }
                }.padding(20).frame(maxWidth: 1200).frame(maxWidth: .infinity)
            }.background(theme.background)
                .navigationTitle("NodePulse")
                .searchable(text: $search, prompt: L10n.text("搜索名称、IP 或系统"))
                .refreshable { await store.refresh() }
                .toolbar {
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        Button { classicLayout.toggle() } label: {
                            Image(systemName: classicLayout ? "rectangle.grid.1x2" : "square.grid.2x2")
                                .contentTransition(.symbolEffect(.replace))
                        }.accessibilityLabel(classicLayout ? L10n.text("切换到默认布局") : L10n.text("切换到经典布局"))
                            .accessibilityValue(classicLayout ? L10n.text("经典") : L10n.text("默认"))
                        Button { sheet = .add } label: { Image(systemName: "plus") }.accessibilityLabel(L10n.text("添加探针"))
                        Button { sheet = .settings } label: { Image(systemName: "gearshape") }.accessibilityLabel(L10n.text("设置"))
                    }
                }
                .sheet(item: $sheet) { selection in
                    switch selection {
                    case .add: AddEndpointView(store: store)
                    case .settings: SettingsView(store: store)
                    case .endpoints: NavigationStack { EndpointList(store: store) }
                    }
                }
                .onChange(of: failures) { _, _ in errorDismissed = false }
                .nodeDeletion(store: store, node: $deleting)
                .onChange(of: store.pairingURL) { _, value in if value != nil { sheet = .add } }
                .animation(reduceMotion ? nil : .smooth(duration: 0.6), value: store.nodes.map { $0.snapshot.cpuUsage })
                .animation(reduceMotion ? nil : .spring(duration: 0.45, bounce: 0.12), value: classicLayout)
                .task {
                    if store.pairingURL != nil { sheet = .add }
                    #if DEBUG
                    if ProcessInfo.processInfo.arguments.contains("-show-add") || ProcessInfo.processInfo.arguments.contains("-show-pair") { sheet = .add }
                    #endif
                }
        }
    }
    private var emptyState: some View {
        VStack(spacing: 22) {
            Image(systemName: "waveform.path.ecg.rectangle").font(.system(size: 76, weight: .ultraLight)).foregroundStyle(theme.ink.gradient)
                .padding(30).background(theme.ink.opacity(0.07), in: RoundedRectangle(cornerRadius: 40))
            Text(L10n.text("每个节点，尽在掌握")).font(.title2.bold())
            Text(L10n.text("连接你的 Linux 探针，实时查看\n服务器的健康状态与资源趋势。"))
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center).lineSpacing(5)
            Button { sheet = .add } label: { Label(L10n.text("添加探针"), systemImage: "plus").frame(maxWidth: .infinity).padding(8) }.buttonStyle(.borderedProminent).tint(theme.accent)
            Button(L10n.text("体验演示数据")) { store.demoMode = true; Task { await store.refresh() } }.foregroundStyle(theme.ink)
        }.padding(.vertical, 64).frame(maxWidth: 400)
    }
}

struct SummaryHeader: View {
    @Environment(\.pulseTheme) private var theme
    var nodes: [NodeItem]
    private var online: [NodeItem] { nodes.filter(\.online) }
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack {
                Label(L10n.text("集群概览"), systemImage: "waveform.path.ecg").font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                Spacer(); Text(L10n.text("实时")).font(.caption.weight(.medium)).foregroundStyle(theme.ink)
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(online.count)").font(.system(size: 46, weight: .semibold, design: .rounded)).contentTransition(.numericText())
                Text(L10n.text("/ %@ 节点在线", String(describing: nodes.count))).font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                Image(systemName: "antenna.radiowaves.left.and.right").font(.system(size: 32, weight: .light)).foregroundStyle(theme.ink.opacity(0.6))
            }
            HStack {
                StatTile(title: L10n.text("平均 CPU"), value: String(format: "%.0f%%", online.isEmpty ? 0 : online.map { $0.snapshot.cpuUsage }.reduce(0,+) / Double(online.count)), symbol: "cpu")
                StatTile(title: L10n.text("平均内存"), value: String(format: "%.0f%%", online.isEmpty ? 0 : online.map { $0.snapshot.memPercent }.reduce(0,+) / Double(online.count)), symbol: "memorychip")
            }
            Divider().opacity(0.5)
            HStack {
                StatTile(title: L10n.text("总上行"), value: PulseFormat.rate(online.map { $0.snapshot.netTxRate }.reduce(0,+)), symbol: "arrow.up.right")
                StatTile(title: L10n.text("总下行"), value: PulseFormat.rate(online.map { $0.snapshot.netRxRate }.reduce(0,+)), symbol: "arrow.down.left")
            }
        }.padding(24).background {
            RoundedRectangle(cornerRadius: 28).fill(.regularMaterial)
                .overlay { RoundedRectangle(cornerRadius: 28).fill(LinearGradient(colors: [theme.ink.opacity(0.12), theme.secondaryInk.opacity(0.04), .clear], startPoint: .topLeading, endPoint: .bottomTrailing)) }
        }
    }
}

struct NodeCard: View {
    @Environment(\.pulseTheme) private var theme
    var item: NodeItem
    var index: Int
    var locations: GeolocationStore
    var demo = false
    @State private var appeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        VStack(spacing: 20) {
            HStack(spacing: 12) {
                OSBadge(os: item.snapshot.os)
                VStack(alignment: .leading, spacing: 5) {
                    Text(item.snapshot.name).font(.headline).foregroundStyle(.primary).lineLimit(1)
                    Text(item.snapshot.os).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                VStack(alignment: .trailing, spacing: 6) {
                    OnlineStatus(online: item.online)
                    if item.usesEndToEndEncryption { EndToEndBadge() }
                    if item.endToEnd { Text(L10n.text("中继")).font(.system(size: 10, weight: .medium)).padding(.horizontal, 7).padding(.vertical, 3).background(theme.secondaryInk.opacity(0.12), in: Capsule()).foregroundStyle(theme.secondaryInk) }
                }
            }
            NodeLocation(ip: item.snapshot.egressIp, locations: locations, demo: demo)
            HStack {
                RingGauge(title: "CPU", value: item.snapshot.cpuUsage)
                RingGauge(title: L10n.text("内存"), value: item.snapshot.memPercent)
                RingGauge(title: L10n.text("磁盘"), value: item.snapshot.diskTotal > 0 ? 100 * item.snapshot.diskUsed / item.snapshot.diskTotal : 0)
            }
            Sparkline(history: item.history)
            HStack {
                Text("↑ \(PulseFormat.rate(item.snapshot.netTxRate))")
                Spacer(); Text("↓ \(PulseFormat.rate(item.snapshot.netRxRate))")
            }.font(.caption.monospacedDigit()).foregroundStyle(.secondary).contentTransition(.numericText())
            HStack {
                Text(L10n.text("负载 %@", String(format: "%.2f", item.snapshot.load.first ?? 0)))
                Spacer()
                Text(item.online ? PulseFormat.uptime(item.snapshot.uptime) : PulseFormat.ago(item.snapshot.ts))
            }.font(.caption2).foregroundStyle(.secondary)
        }.pulsePanel().saturation(item.online ? 1 : 0).opacity(item.online ? 1 : 0.7)
            .opacity(appeared ? 1 : 0).offset(y: appeared ? 0 : 14)
            .onAppear { withAnimation(reduceMotion ? nil : .spring(duration: 0.55).delay(Double(index % 6) * 0.06)) { appeared = true } }
    }
}
