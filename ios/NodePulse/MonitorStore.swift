import Foundation
import Observation

struct HistorySample: Hashable {
    var date: Date
    var cpu: Double
    var memPercent: Double
    var rxRate: Double
    var txRate: Double
    var seq: UInt32? = nil
    static func displayed(in history: [Self], at selection: Date?) -> Self? {
        guard let selection else { return history.last }
        return history.min { abs($0.date.timeIntervalSince(selection)) < abs($1.date.timeIntervalSince(selection)) }
    }
}
struct HistoryCursor: Codable, Hashable {
    var epoch: String
    var since: UInt32
}
struct HistoryBatch: Codable, Hashable {
    var epoch: String
    var seq: UInt32
    var full: Bool
    var samples: [[Double]]
    func points() throws -> [HistorySample] {
        guard epoch.count == 16, epoch.allSatisfy({ "0123456789abcdef".contains($0) }),
              let boot = UInt64(epoch, radix: 16), boot != 0, samples.count <= 120 else { throw ProbeError.parse }
        var seen = Set<UInt32>(), previous: UInt32?
        let points = try samples.map { row -> HistorySample in
            guard row.count == 11, row.allSatisfy(\.isFinite), row[0] >= 0, row[0] <= Double(UInt32.max),
                  row[0].rounded() == row[0], row[1] > 0 else { throw ProbeError.parse }
            let number = UInt32(row[0])
            guard seen.insert(number).inserted else { throw ProbeError.parse }
            if let previous {
                guard number &- previous > 0, number &- previous < 0x80000000 else { throw ProbeError.parse }
            }
            previous = number
            return HistorySample(date: Date(timeIntervalSince1970: row[1]), cpu: row[2], memPercent: row[3],
                                 rxRate: row[9], txRate: row[10], seq: number)
        }
        guard points.isEmpty || points.last?.seq == seq else { throw ProbeError.parse }
        return points
    }
}
struct HistoryWindow {
    private(set) var cursor: HistoryCursor?
    private(set) var samples: [HistorySample] = []
    mutating func invalidate() { cursor = nil }
    @discardableResult mutating func merge(_ batch: HistoryBatch) -> Bool {
        guard let incoming = try? batch.points() else { invalidate(); return false }
        if let cursor, cursor.epoch == batch.epoch, batch.seq &- cursor.since >= 0x80000000 { return true }
        if batch.full {
            guard !incoming.isEmpty || batch.seq == 0 else { invalidate(); return false }
            samples = incoming
        } else {
            guard let cursor, cursor.epoch == batch.epoch else { invalidate(); return false }
            let fresh = incoming.filter { ($0.seq! &- cursor.since) > 0 && ($0.seq! &- cursor.since) < 0x80000000 }
            var next = cursor.since
            for point in fresh {
                guard point.seq == next &+ 1 else { invalidate(); return false }
                next = point.seq!
            }
            guard next == batch.seq else { invalidate(); return false }
            samples.append(contentsOf: fresh)
        }
        samples.sort { $0.date < $1.date || ($0.date == $1.date && $0.seq != $1.seq && ($1.seq! &- $0.seq!) < 0x80000000) }
        if let newest = samples.last?.date {
            samples = Array(samples.filter { $0.date > newest.addingTimeInterval(-120) }.suffix(120))
        }
        cursor = HistoryCursor(epoch: batch.epoch, since: batch.seq)
        return true
    }
}
struct NodeItem: Identifiable {
    var key: String
    var endpointID: UUID
    var endpointName: String
    var snapshot: NodeSnapshot
    var online: Bool
    var history: [HistorySample] = []
    var historyWindow = HistoryWindow()
    var probeInterval: Double = 5
    var endToEnd = false
    var usesEndToEndEncryption = false
    var id: String { key }
    var connectionLabel: String {
        guard endToEnd else { return L10n.text("直连") }
        return endpointName.isEmpty || endpointName == snapshot.name ? L10n.text("中继") : L10n.text("经由 %@", String(describing: endpointName))
    }
}
struct HiddenNode: Codable, Identifiable {
    var id: String
    var endpointID: UUID
    var name: String
}
struct EndpointStatus {
    var lastSuccess: Date?
    var latency: Double?
    var error: String?
    var droppedBlobs = 0
}

@Observable @MainActor
final class MonitorStore {
    let locations = GeolocationStore()
    var pairingURL: URL?
    private(set) var endpoints: [Endpoint]
    private(set) var nodes: [NodeItem] = []
    private(set) var hiddenNodes: [HiddenNode]
    private(set) var statuses: [UUID: EndpointStatus] = [:]
    var refreshInterval: Double { didSet { defaults.set(refreshInterval, forKey: "refreshInterval") } }
    var demoMode: Bool { didSet {
        defaults.set(demoMode, forKey: "demoMode")
        generation += 1; nodes = []; statuses = [:]
    } }
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let secrets: any SecretStorage
    @ObservationIgnored private var polling: Task<Void, Never>?
    @ObservationIgnored private var snapshotOnlyRelays = Set<UUID>()
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var refreshing = false
    @ObservationIgnored private let demoStart = Date()
    @ObservationIgnored private let demoID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    init(defaults: UserDefaults = .standard, secrets: any SecretStorage = SecretStore()) {
        self.defaults = defaults
        self.secrets = secrets
        endpoints = defaults.data(forKey: "endpoints").flatMap { try? JSONDecoder().decode([Endpoint].self, from: $0) } ?? []
        hiddenNodes = defaults.data(forKey: "hiddenNodes").flatMap { try? JSONDecoder().decode([HiddenNode].self, from: $0) } ?? []
        let interval = defaults.double(forKey: "refreshInterval")
        refreshInterval = interval > 0 ? interval : 1
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
            snapshotOnlyRelays.remove(endpoint.id)
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
        hiddenNodes.removeAll { $0.endpointID == endpoint.id }; persistHiddenNodes()
        statuses[endpoint.id] = nil; generation += 1; persist()
    }
    func removableEndpoint(for node: NodeItem) -> Endpoint? {
        guard let endpoint = endpoints.first(where: { $0.id == node.endpointID }),
              !endpoint.kind.isGroup,
              nodes.filter({ $0.endpointID == endpoint.id }).count == 1,
              !hiddenNodes.contains(where: { $0.endpointID == endpoint.id }) else { return nil }
        return endpoint
    }
    func deleteNode(_ node: NodeItem, removeEndpoint: Bool = false) throws {
        if removeEndpoint {
            guard let endpoint = removableEndpoint(for: node) else { throw ProbeError.transport(L10n.text("此节点不能单独删除接入点，请仅删除节点")) }
            try delete(endpoint)
            return
        }
        guard !hiddenNodes.contains(where: { $0.id == node.key }) else { return }
        hiddenNodes.append(HiddenNode(id: node.key, endpointID: node.endpointID, name: node.snapshot.name))
        nodes.removeAll { $0.key == node.key }
        generation += 1; persistHiddenNodes()
    }
    func restoreNode(_ node: HiddenNode) {
        hiddenNodes.removeAll { $0.id == node.id }
        generation += 1; persistHiddenNodes()
    }
    private func persistHiddenNodes() { defaults.set(try? JSONEncoder().encode(hiddenNodes), forKey: "hiddenNodes") }
    func secret(for endpoint: Endpoint) throws -> String { try secrets.get(endpoint.id) }
    func groupSecret(for endpoint: Endpoint) throws -> String { try secrets.getGroup(endpoint.id) }
    private func persist() { defaults.set(try? JSONEncoder().encode(endpoints), forKey: "endpoints") }
    func start() {
        guard polling == nil else { return }
        snapshotOnlyRelays.removeAll()
        for index in nodes.indices { nodes[index].historyWindow.invalidate() }
        polling = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let began = ContinuousClock.now
                await self.refresh()
                let elapsed = began.duration(to: .now)
                do { try await Task.sleep(for: max(.milliseconds(50), .seconds(max(0.2, self.refreshInterval)) - elapsed)) }
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
                let history = !snapshotOnlyRelays.contains(endpoint.id)
                let cursors = Dictionary(uniqueKeysWithValues: nodes.filter { $0.endpointID == endpoint.id }.compactMap { node in
                    node.historyWindow.cursor.map { (node.snapshot.id, $0) }
                })
                group.addTask {
                    let start = ContinuousClock.now
                    let result: Result<ProbeFetch, Error>
                    do {
                        let credentials = try secret.get()
                        result = .success(try await fetchProbe(endpoint, secret: credentials.0, groupSecret: credentials.1, cursors: cursors, history: history))
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
                    if fetched.legacyRelay { snapshotOnlyRelays.insert(endpoint.id) }
                    apply(endpoint, result: .success(fetched.snapshots), latency: latency,
                          ages: fetched.ages, droppedBlobs: fetched.droppedBlobs, histories: fetched.histories,
                          invalidHistories: fetched.invalidHistories)
                case .failure(let error): apply(endpoint, result: .failure(error), latency: latency)
                }
            }
        }
    }
    func apply(_ endpoint: Endpoint, result: Result<[NodeSnapshot], Error>, latency: Double, now: Date = Date(),
               ages: [String: Double] = [:], droppedBlobs: Int = 0,
               histories: [String: HistoryBatch] = [:], invalidHistories: Set<String> = []) {
        switch result {
        case .failure(let error):
            var status = statuses[endpoint.id] ?? EndpointStatus()
            status.error = error.localizedDescription; statuses[endpoint.id] = status
            for index in nodes.indices where nodes[index].endpointID == endpoint.id {
                nodes[index].online = false; nodes[index].historyWindow.invalidate()
            }
        case .success(let snapshots):
            statuses[endpoint.id] = EndpointStatus(lastSuccess: now, latency: latency, error: nil, droppedBlobs: droppedBlobs)
            for snapshot in snapshots {
                let key = "\(endpoint.id)/\(snapshot.id)"
                guard !hiddenNodes.contains(where: { $0.id == key }) else { continue }
                let index = nodes.firstIndex { $0.key == key }
                let old = index.map { nodes[$0] }
                let timestamp = snapshot.ts
                let previousTimestamp = old?.snapshot.ts ?? timestamp
                let delta = (timestamp ?? 0) - (previousTimestamp ?? timestamp ?? 0)
                let cadence = delta > 0 && (!endpoint.kind.isGroup || delta <= 600) ? delta : (old?.probeInterval ?? 5)
                let stale: Bool
                if endpoint.kind.isGroup {
                    let stamp = snapshot.ts ?? 0
                    stale = (ages[snapshot.id] ?? .infinity) > max(30, 4 * cadence) ||
                        !stamp.isFinite || abs(now.timeIntervalSince1970 - stamp) > 600
                } else {
                    stale = false
                }
                var item = NodeItem(key: key, endpointID: endpoint.id, endpointName: endpoint.name,
                                    snapshot: snapshot, online: !stale, history: old?.history ?? [])
                item.probeInterval = cadence
                item.endToEnd = endpoint.kind.isGroup
                switch endpoint.kind {
                case .https, .groupHTTPS: item.usesEndToEndEncryption = false
                case .direct, .groupTCP: item.usesEndToEndEncryption = true
                }
                item.historyWindow = old?.historyWindow ?? HistoryWindow()
                if invalidHistories.contains(snapshot.id) {
                    item.historyWindow.invalidate()
                } else if let batch = histories[snapshot.id] {
                    if item.historyWindow.merge(batch) { item.history = item.historyWindow.samples }
                } else {
                    item.historyWindow.invalidate()
                    item.history.append(HistorySample(date: now, cpu: snapshot.cpuUsage, memPercent: snapshot.memPercent,
                                                      rxRate: snapshot.netRxRate, txRate: snapshot.netTxRate))
                    item.history = Array(item.history.filter { $0.date > now.addingTimeInterval(-120) }.suffix(120))
                }
                if let index { nodes[index] = item } else { nodes.append(item) }
            }
            let ids = Set(snapshots.map { "\(endpoint.id)/\($0.id)" })
            for index in nodes.indices where nodes[index].endpointID == endpoint.id && !ids.contains(nodes[index].key) {
                nodes[index].online = false
            }
        }
    }
    static func demoSample(at date: Date, since start: Date, index: Int) -> HistorySample {
        let phase = date.timeIntervalSince(start) * 0.18
        let wave = sin(phase + Double(index))
        let rx = 100000 + 80000 * wave
        return HistorySample(date: date, cpu: 25 + 18 * wave,
                             memPercent: 48 + 8 * sin(phase * 0.4 + Double(index)),
                             rxRate: rx, txRate: rx * 0.3)
    }
    private func demo() {
        let now = Date()
        let endpoint = Endpoint(id: demoID, name: L10n.text("演示"), kind: .direct(host: "localhost", port: 9000))
        let specs = [("OpenWrt 23.05", "mips", L10n.text("家庭路由器")), ("Ubuntu 24.04 LTS", "x86_64", L10n.text("东京 VPS")),
                     ("Debian 12", "aarch64", L10n.text("中继节点")), ("Alpine Linux", "armv7", L10n.text("离线设备")),
                     ("Ubuntu 22.04 LTS", "aarch64", L10n.text("工作站"))]
        let snapshots = specs.enumerated().map { index, spec -> NodeSnapshot in
            let sample = Self.demoSample(at: now, since: demoStart, index: index)
            var s = NodeSnapshot(); s.id = "demo-\(index)"; s.name = spec.2; s.hostname = "node-\(index)"
            s.os = spec.0; s.arch = spec.1; s.kernel = "6.6.32"; s.cpuModel = index == 0 ? "MediaTek MT7621" : "Virtual CPU"
            s.cpuCores = index == 0 ? 2 : 4; s.cpuUsage = sample.cpu
            s.memTotal = index == 0 ? 256 * 1048576 : 4 * 1073741824
            s.memUsed = s.memTotal * sample.memPercent / 100
            s.netRxRate = sample.rxRate; s.netTxRate = sample.txRate
            s.load = [s.cpuUsage / 50, 0.7, 0.5]; s.diskTotal = 32 * 1073741824; s.diskUsed = s.diskTotal * 0.4
            s.ts = now.timeIntervalSince1970 - (index == 3 ? 300 : 0)
            s.version = "0.1.0"; s.ips = ["192.168.1.\(index + 1)"]; s.egressIp = "1.1.1.1"
            s.uptime = 86400 * Double(index + 1); s.temp = 42 + 3 * sin(now.timeIntervalSince(demoStart) * 0.18); return s
        }
        let relay = Endpoint(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, name: L10n.text("演示中继"), kind: .groupTCP(host: "localhost", port: 9001))
        #if DEBUG
        if defaults.bool(forKey: "demoChartStreams") {
            let elapsed = floor(now.timeIntervalSince(demoStart))
            let latest = UInt32(elapsed) + 120
            let rows = (0..<120).map { offset -> [Double] in
                let date = demoStart.addingTimeInterval(elapsed + Double(offset - 119))
                let point = Self.demoSample(at: date, since: demoStart, index: 0)
                return [Double(latest - 119 + UInt32(offset)), date.timeIntervalSince1970,
                        point.cpu, point.memPercent, 0, 0, 0, 0, 0, point.rxRate, point.txRate]
            }
            let batch = HistoryBatch(epoch: "0000000000000001", seq: latest, full: true, samples: rows)
            apply(endpoint, result: .success([snapshots[0]]), latency: 12, now: now, histories: [snapshots[0].id: batch])
            apply(relay, result: .success([snapshots[2]]), latency: 12, now: now, ages: [snapshots[2].id: 0])
            return
        }
        #endif
        apply(endpoint, result: .success(snapshots.enumerated().filter { $0.offset != 2 && $0.offset != 3 }.map(\.element)), latency: 12, now: now)
        apply(relay, result: .success([snapshots[2], snapshots[3]]), latency: 12, now: now, ages: [snapshots[2].id: 0, snapshots[3].id: 300])
        for index in nodes.indices where nodes[index].history.count == 1 {
            guard let demoIndex = Int(nodes[index].snapshot.id.dropFirst("demo-".count)) else { continue }
            nodes[index].history = (0..<120).map { tick in
                Self.demoSample(at: now.addingTimeInterval(Double(tick - 119)), since: demoStart, index: demoIndex)
            }
        }
    }
}
