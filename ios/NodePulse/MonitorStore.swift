import Foundation
import Observation

struct HistorySample: Hashable {
    var date: Date
    var cpu: Double
    var memPercent: Double
    var rxRate: Double
    var txRate: Double
}
struct NodeItem: Identifiable {
    var key: String
    var endpointID: UUID
    var endpointName: String
    var snapshot: NodeSnapshot
    var online: Bool
    var history: [HistorySample] = []
    var probeInterval: Double = 5
    var endToEnd = false
    var id: String { key }
}
struct EndpointStatus {
    var lastSuccess: Date?
    var latency: Double?
    var error: String?
    var droppedBlobs = 0
}

@Observable @MainActor
final class MonitorStore {
    var pairingURL: URL?
    private(set) var endpoints: [Endpoint]
    private(set) var nodes: [NodeItem] = []
    private(set) var statuses: [UUID: EndpointStatus] = [:]
    var refreshInterval: Double { didSet { defaults.set(refreshInterval, forKey: "refreshInterval") } }
    var demoMode: Bool { didSet {
        defaults.set(demoMode, forKey: "demoMode")
        generation += 1; nodes = []; statuses = [:]
    } }
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let secrets: any SecretStorage
    @ObservationIgnored private var polling: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var refreshing = false
    @ObservationIgnored private var demoTick = 0.0
    @ObservationIgnored private let demoID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    init(defaults: UserDefaults = .standard, secrets: any SecretStorage = SecretStore()) {
        self.defaults = defaults
        self.secrets = secrets
        endpoints = defaults.data(forKey: "endpoints").flatMap { try? JSONDecoder().decode([Endpoint].self, from: $0) } ?? []
        let interval = defaults.double(forKey: "refreshInterval")
        refreshInterval = interval > 0 ? interval : 3
        demoMode = defaults.bool(forKey: "demoMode")
    }
    func save(_ endpoint: Endpoint, secret: String, groupSecret: String? = nil) throws {
        if endpoint.kind.isGroup && (groupSecret?.isEmpty != false || secret.isEmpty) { throw ProbeError.missingSecret }
        let oldSecret = try? secrets.get(endpoint.id), oldGroup = try? secrets.getGroup(endpoint.id)
        do {
            if endpoint.kind.isGroup, let groupSecret { try secrets.setGroup(groupSecret, for: endpoint.id) }
            try secrets.set(secret, for: endpoint.id)
            if !endpoint.kind.isGroup { try secrets.deleteGroup(endpoint.id) }
        } catch {
            if let oldSecret { try? secrets.set(oldSecret, for: endpoint.id) } else { try? secrets.delete(endpoint.id) }
            if let oldGroup { try? secrets.setGroup(oldGroup, for: endpoint.id) } else { try? secrets.deleteGroup(endpoint.id) }
            throw error
        }
        if endpoints.first(where: { $0.id == endpoint.id })?.kind != endpoint.kind ||
            oldSecret != secret || oldGroup != groupSecret {
            nodes.removeAll { $0.endpointID == endpoint.id }; statuses[endpoint.id] = nil
        }
        if let index = endpoints.firstIndex(where: { $0.id == endpoint.id }) { endpoints[index] = endpoint }
        else { endpoints.append(endpoint) }
        generation += 1
        for index in nodes.indices where nodes[index].endpointID == endpoint.id { nodes[index].endpointName = endpoint.name }
        persist()
    }
    func delete(_ endpoint: Endpoint) throws {
        try secrets.deleteGroup(endpoint.id)
        try secrets.delete(endpoint.id)
        endpoints.removeAll { $0.id == endpoint.id }; nodes.removeAll { $0.endpointID == endpoint.id }
        statuses[endpoint.id] = nil; generation += 1; persist()
    }
    func secret(for endpoint: Endpoint) throws -> String { try secrets.get(endpoint.id) }
    func groupSecret(for endpoint: Endpoint) throws -> String { try secrets.getGroup(endpoint.id) }
    private func persist() { defaults.set(try? JSONEncoder().encode(endpoints), forKey: "endpoints") }
    func start() {
        guard polling == nil else { return }
        polling = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                do { try await Task.sleep(for: .seconds(max(0.2, self.refreshInterval))) }
                catch { return }
            }
        }
    }
    func stop() { polling?.cancel(); polling = nil; generation += 1 }
    func testConnection(_ endpoint: Endpoint, secret: String, groupSecret: String? = nil) async -> Result<Int, Error> {
        do { return .success(try await fetchProbe(endpoint, secret: secret, groupSecret: groupSecret).snapshots.count) }
        catch { return .failure(error) }
    }
    func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        if demoMode { demo(); return }
        let current = generation
        let requests = endpoints.map { endpoint in (endpoint, Result {
            let group = endpoint.kind.isGroup ? try secrets.getGroup(endpoint.id) : nil
            return (try secrets.get(endpoint.id), group)
        }) }
        await withTaskGroup(of: (Endpoint, Result<ProbeFetch, Error>, Double).self) { group in
            for (endpoint, secret) in requests {
                group.addTask {
                    let start = ContinuousClock.now
                    let result: Result<ProbeFetch, Error>
                    do {
                        let credentials = try secret.get()
                        result = .success(try await fetchProbe(endpoint, secret: credentials.0, groupSecret: credentials.1))
                    }
                    catch { result = .failure(error) }
                    let duration = start.duration(to: .now).components
                    return (endpoint, result, Double(duration.seconds) * 1000 + Double(duration.attoseconds) / 1e15)
                }
            }
            for await (endpoint, result, latency) in group {
                guard current == generation, !Task.isCancelled else { continue }
                switch result {
                case .success(let fetched):
                    apply(endpoint, result: .success(fetched.snapshots), latency: latency,
                          ages: fetched.ages, droppedBlobs: fetched.droppedBlobs)
                case .failure(let error): apply(endpoint, result: .failure(error), latency: latency)
                }
            }
        }
    }
    func apply(_ endpoint: Endpoint, result: Result<[NodeSnapshot], Error>, latency: Double, now: Date = Date(),
               ages: [String: Double] = [:], droppedBlobs: Int = 0) {
        switch result {
        case .failure(let error):
            var status = statuses[endpoint.id] ?? EndpointStatus()
            status.error = error.localizedDescription; statuses[endpoint.id] = status
            for index in nodes.indices where nodes[index].endpointID == endpoint.id { nodes[index].online = false }
        case .success(let snapshots):
            statuses[endpoint.id] = EndpointStatus(lastSuccess: now, latency: latency, error: nil, droppedBlobs: droppedBlobs)
            let upstreamTS = snapshots.first(where: { $0.relay != true })?.ts ?? now.timeIntervalSince1970
            for snapshot in snapshots {
                let key = "\(endpoint.id)/\(snapshot.id)"
                let index = nodes.firstIndex { $0.key == key }
                let old = index.map { nodes[$0] }
                let timestamp = !endpoint.kind.isGroup && snapshot.relay == true ? (snapshot.lastSeen ?? snapshot.ts) : snapshot.ts
                let previousTimestamp = old.map { !endpoint.kind.isGroup && $0.snapshot.relay == true ? ($0.snapshot.lastSeen ?? $0.snapshot.ts) : $0.snapshot.ts } ?? timestamp
                let delta = (timestamp ?? 0) - (previousTimestamp ?? timestamp ?? 0)
                let cadence = delta > 0 && (!endpoint.kind.isGroup || delta <= 600) ? delta : (old?.probeInterval ?? 5)
                let stale: Bool
                if endpoint.kind.isGroup {
                    let stamp = snapshot.ts ?? 0
                    stale = (ages[snapshot.id] ?? .infinity) > max(30, 4 * cadence) ||
                        !stamp.isFinite || abs(now.timeIntervalSince1970 - stamp) > 600
                } else {
                    stale = snapshot.relay == true &&
                        upstreamTS - (snapshot.lastSeen ?? snapshot.ts ?? 0) > max(30, 4 * cadence)
                }
                var item = NodeItem(key: key, endpointID: endpoint.id, endpointName: endpoint.name,
                                    snapshot: snapshot, online: !stale, history: old?.history ?? [])
                item.probeInterval = cadence
                item.endToEnd = endpoint.kind.isGroup
                item.history.append(HistorySample(date: now, cpu: snapshot.cpuUsage, memPercent: snapshot.memPercent,
                                                  rxRate: snapshot.netRxRate, txRate: snapshot.netTxRate))
                item.history = Array(item.history.suffix(120))
                if let index { nodes[index] = item } else { nodes.append(item) }
            }
            let ids = Set(snapshots.map { "\(endpoint.id)/\($0.id)" })
            for index in nodes.indices where nodes[index].endpointID == endpoint.id && !ids.contains(nodes[index].key) {
                nodes[index].online = false
            }
        }
    }
    private func demo() {
        demoTick += 0.18
        let endpoint = Endpoint(id: demoID, name: "演示", kind: .https(urlString: "https://demo.invalid"))
        let specs = [("OpenWrt 23.05", "mips", "家庭路由器"), ("Ubuntu 24.04 LTS", "x86_64", "东京 VPS"),
                     ("Debian 12", "aarch64", "中继节点"), ("Alpine Linux", "armv7", "离线设备"),
                     ("Ubuntu 22.04 LTS", "aarch64", "工作站")]
        let snapshots = specs.enumerated().map { index, spec -> NodeSnapshot in
            var s = NodeSnapshot(); s.id = "demo-\(index)"; s.name = spec.2; s.hostname = "node-\(index)"
            s.os = spec.0; s.arch = spec.1; s.kernel = "6.6.32"; s.cpuModel = index == 0 ? "MediaTek MT7621" : "Virtual CPU"
            s.cpuCores = index == 0 ? 2 : 4; s.cpuUsage = 25 + 18 * sin(demoTick + Double(index))
            s.memTotal = index == 0 ? 256 * 1048576 : 4 * 1073741824
            s.memUsed = s.memTotal * (0.48 + 0.08 * sin(demoTick * 0.4 + Double(index)))
            s.netRxRate = 100000 + 80000 * sin(demoTick + Double(index)); s.netTxRate = s.netRxRate * 0.3
            s.load = [s.cpuUsage / 50, 0.7, 0.5]; s.diskTotal = 32 * 1073741824; s.diskUsed = s.diskTotal * 0.4
            s.ts = Date().timeIntervalSince1970 - (index == 3 ? 300 : 0); s.relay = index == 2 || index == 3
            s.lastSeen = s.relay == true ? s.ts : nil; s.version = "0.1.0"; s.ips = ["192.168.1.\(index + 1)"]
            s.uptime = 86400 * Double(index + 1); s.temp = 42 + 3 * sin(demoTick); return s
        }
        apply(endpoint, result: .success(snapshots), latency: 12)
        for index in nodes.indices where nodes[index].history.count == 1 {
            let s = nodes[index].snapshot
            nodes[index].history = (0..<40).map { tick in
                let wave = sin(Double(tick) * 0.22 + Double(index))
                return HistorySample(date: Date().addingTimeInterval(Double(tick - 39) * 3), cpu: max(0, s.cpuUsage + wave * 12), memPercent: s.memPercent + wave * 3, rxRate: max(0, s.netRxRate * (1 + wave * 0.3)), txRate: max(0, s.netTxRate * (1 + wave * 0.25)))
            }
        }
    }
}
