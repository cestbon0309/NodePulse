import SwiftUI

struct ContentView: View {
    @Bindable var store: MonitorStore
    @State private var filter = "全部"
    @State private var search = ""
    @State private var sheet: DashboardSheet?
    @State private var errorDismissed = false
    @State private var deleting: NodeItem?
    @AppStorage("classicLayout") private var classicLayout = false
    @Namespace private var zoom
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    enum DashboardSheet: String, Identifiable { case add, settings, endpoints; var id: String { rawValue } }
    private var visible: [NodeItem] {
        store.nodes.filter { item in
            (filter == "全部" || (filter == "在线" ? item.online : !item.online)) &&
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
                            Button { sheet = .endpoints } label: { Label("\(failures) 个接入点连接失败", systemImage: "exclamationmark.triangle.fill") }
                            Spacer()
                            Button { errorDismissed = true } label: { Image(systemName: "xmark") }.accessibilityLabel("关闭提示")
                        }.font(.caption.weight(.medium)).foregroundStyle(.orange).padding(14).background(.orange.opacity(0.1), in: Capsule())
                    }
                    if store.endpoints.isEmpty && !store.demoMode {
                        emptyState
                    } else {
                        SummaryHeader(nodes: store.nodes)
                        Picker("节点筛选", selection: $filter) { ForEach(["全部", "在线", "离线"], id: \.self) { Text($0) } }.pickerStyle(.segmented)
                        LazyVGrid(columns: columns, spacing: classicLayout ? 12 : 18) {
                            ForEach(Array(visible.enumerated()), id: \.element.key) { index, item in
                                NavigationLink {
                                    NodeDetail(store: store, nodeKey: item.key).zoomDestination(item.key, namespace: zoom)
                                } label: {
                                    Group {
                                        if classicLayout { CompactNodeCard(item: item) }
                                        else { NodeCard(item: item, index: index) }
                                    }.zoomSource(item.key, namespace: zoom)
                                }
                                    .buttonStyle(PressStyle())
                                    .contextMenu {
                                        Button("复制 IP", systemImage: "doc.on.doc") { UIPasteboard.general.string = item.snapshot.ips.joined(separator: "\n") }
                                        NavigationLink { NodeDetail(store: store, nodeKey: item.key) } label: { Label("查看详情", systemImage: "info.circle") }
                                        Button("删除", systemImage: "trash", role: .destructive) { deleting = item }
                                    }
                            }
                        }
                        if visible.isEmpty { ContentUnavailableView("没有匹配的节点", systemImage: "magnifyingglass", description: Text("试试其他名称、IP 或系统")) }
                    }
                }.padding(20).frame(maxWidth: 1200).frame(maxWidth: .infinity)
            }.background(Color(uiColor: .systemGroupedBackground))
                .navigationTitle("NodePulse")
                .searchable(text: $search, prompt: "搜索名称、IP 或系统")
                .refreshable { await store.refresh() }
                .toolbar {
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        Button { classicLayout.toggle() } label: {
                            Image(systemName: classicLayout ? "rectangle.grid.1x2" : "square.grid.2x2")
                                .contentTransition(.symbolEffect(.replace))
                        }.accessibilityLabel(classicLayout ? "切换到默认布局" : "切换到经典布局")
                            .accessibilityValue(classicLayout ? "经典" : "默认")
                        Button { sheet = .add } label: { Image(systemName: "plus") }.accessibilityLabel("添加探针")
                        Button { sheet = .settings } label: { Image(systemName: "gearshape") }.accessibilityLabel("设置")
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
            Image(systemName: "waveform.path.ecg.rectangle").font(.system(size: 76, weight: .ultraLight)).foregroundStyle(.mint.gradient)
                .padding(30).background(.mint.opacity(0.07), in: RoundedRectangle(cornerRadius: 40))
            Text("每个节点，尽在掌握").font(.title2.bold())
            Text("连接你的 Linux 探针，实时查看\n服务器的健康状态与资源趋势。")
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center).lineSpacing(5)
            Button { sheet = .add } label: { Label("添加探针", systemImage: "plus").frame(maxWidth: .infinity).padding(8) }.buttonStyle(.borderedProminent).tint(.mint)
            Button("体验演示数据") { store.demoMode = true; Task { await store.refresh() } }.foregroundStyle(.mint)
        }.padding(.vertical, 64).frame(maxWidth: 400)
    }
}

struct SummaryHeader: View {
    var nodes: [NodeItem]
    private var online: [NodeItem] { nodes.filter(\.online) }
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack {
                Label("集群概览", systemImage: "waveform.path.ecg").font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                Spacer(); Text("实时").font(.caption.weight(.medium)).foregroundStyle(.mint)
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(online.count)").font(.system(size: 46, weight: .semibold, design: .rounded)).contentTransition(.numericText())
                Text("/ \(nodes.count) 节点在线").font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                Image(systemName: "antenna.radiowaves.left.and.right").font(.system(size: 32, weight: .light)).foregroundStyle(.mint.opacity(0.6))
            }
            HStack {
                StatTile(title: "平均 CPU", value: String(format: "%.0f%%", online.isEmpty ? 0 : online.map { $0.snapshot.cpuUsage }.reduce(0,+) / Double(online.count)), symbol: "cpu")
                StatTile(title: "平均内存", value: String(format: "%.0f%%", online.isEmpty ? 0 : online.map { $0.snapshot.memPercent }.reduce(0,+) / Double(online.count)), symbol: "memorychip")
            }
            Divider().opacity(0.5)
            HStack {
                StatTile(title: "总上行", value: PulseFormat.rate(online.map { $0.snapshot.netTxRate }.reduce(0,+)), symbol: "arrow.up.right")
                StatTile(title: "总下行", value: PulseFormat.rate(online.map { $0.snapshot.netRxRate }.reduce(0,+)), symbol: "arrow.down.left")
            }
        }.padding(24).background {
            RoundedRectangle(cornerRadius: 28).fill(.regularMaterial)
                .overlay { RoundedRectangle(cornerRadius: 28).fill(LinearGradient(colors: [.mint.opacity(0.12), .cyan.opacity(0.04), .clear], startPoint: .topLeading, endPoint: .bottomTrailing)) }
        }
    }
}

struct NodeCard: View {
    var item: NodeItem
    var index: Int
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
                    if item.endToEnd { EndToEndBadge() }
                    if item.endToEnd { Text("中继").font(.system(size: 10, weight: .medium)).padding(.horizontal, 7).padding(.vertical, 3).background(.cyan.opacity(0.12), in: Capsule()).foregroundStyle(.cyan) }
                }
            }
            HStack {
                RingGauge(title: "CPU", value: item.snapshot.cpuUsage)
                RingGauge(title: "内存", value: item.snapshot.memPercent)
                RingGauge(title: "磁盘", value: item.snapshot.diskTotal > 0 ? 100 * item.snapshot.diskUsed / item.snapshot.diskTotal : 0)
            }
            Sparkline(history: item.history)
            HStack {
                Text("↑ \(PulseFormat.rate(item.snapshot.netTxRate))")
                Spacer(); Text("↓ \(PulseFormat.rate(item.snapshot.netRxRate))")
            }.font(.caption.monospacedDigit()).foregroundStyle(.secondary).contentTransition(.numericText())
            HStack {
                Text("负载 \(item.snapshot.load.first ?? 0, specifier: "%.2f")")
                Spacer()
                Text(item.online ? PulseFormat.uptime(item.snapshot.uptime) : PulseFormat.ago(item.snapshot.ts))
            }.font(.caption2).foregroundStyle(.secondary)
        }.pulsePanel().saturation(item.online ? 1 : 0).opacity(item.online ? 1 : 0.7)
            .opacity(appeared ? 1 : 0).offset(y: appeared ? 0 : 14)
            .onAppear { withAnimation(reduceMotion ? nil : .spring(duration: 0.55).delay(Double(index % 6) * 0.06)) { appeared = true } }
    }
}
