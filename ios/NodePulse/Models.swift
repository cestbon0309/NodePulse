import Foundation

struct NodeSnapshot: Codable, Identifiable, Hashable {
    var id = ""
    var name = ""
    var hostname = ""
    var os = ""
    var kernel = ""
    var arch = ""
    var cpuModel = ""
    var cpuCores = 0
    var cpuUsage = 0.0
    var load: [Double] = []
    var memTotal = 0.0
    var memUsed = 0.0
    var swapTotal = 0.0
    var swapUsed = 0.0
    var diskTotal = 0.0
    var diskUsed = 0.0
    var netRx = 0.0
    var netTx = 0.0
    var netRxRate = 0.0
    var netTxRate = 0.0
    var uptime = 0.0
    var procs = 0
    var tcpConns = 0
    var temp: Double?
    var ips: [String] = []
    var ts: Double?
    var version = ""

    enum CodingKeys: String, CodingKey, CaseIterable {
        case id, name, hostname, os, kernel, arch, cpuModel, cpuCores, cpuUsage, load
        case memTotal, memUsed, swapTotal, swapUsed, diskTotal, diskUsed
        case netRx, netTx, netRxRate, netTxRate, uptime, procs, tcpConns, temp, ips, ts, version
    }
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func read<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? c.decode(T.self, forKey: key)) ?? fallback
        }
        id = read(.id, ""); name = read(.name, ""); hostname = read(.hostname, "")
        os = read(.os, ""); kernel = read(.kernel, ""); arch = read(.arch, "")
        cpuModel = read(.cpuModel, ""); cpuCores = read(.cpuCores, 0); cpuUsage = read(.cpuUsage, 0)
        load = read(.load, []); memTotal = read(.memTotal, 0); memUsed = read(.memUsed, 0)
        swapTotal = read(.swapTotal, 0); swapUsed = read(.swapUsed, 0)
        diskTotal = read(.diskTotal, 0); diskUsed = read(.diskUsed, 0)
        netRx = read(.netRx, 0); netTx = read(.netTx, 0)
        netRxRate = read(.netRxRate, 0); netTxRate = read(.netTxRate, 0)
        uptime = read(.uptime, 0); procs = read(.procs, 0); tcpConns = read(.tcpConns, 0)
        temp = try? c.decode(Double.self, forKey: .temp); ips = read(.ips, [])
        ts = try? c.decode(Double.self, forKey: .ts); version = read(.version, "")
    }
    var memPercent: Double { memTotal > 0 ? 100 * memUsed / memTotal : 0 }
}

struct Endpoint: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var kind: Kind
    enum Kind: Codable, Hashable {
        case direct(host: String, port: UInt16)
        case https(urlString: String)
        case groupTCP(host: String, port: UInt16)
        case groupHTTPS(urlString: String)
        var isGroup: Bool {
            switch self { case .groupTCP, .groupHTTPS: return true; default: return false }
        }
    }
}

struct ProbeResponse: Decodable {
    let ok: Bool
    let nodes: [NodeSnapshot]
    static func decode(_ data: Data) throws -> [NodeSnapshot] {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        do {
            let response = try decoder.decode(Self.self, from: data)
            guard response.ok else { throw ProbeError.parse }
            return response.nodes
        } catch { throw ProbeError.parse }
    }
}

enum ProbeError: LocalizedError {
    case timeout, refused, rejected, parse, invalidURL, missingSecret, keychain(Int32), transport(String)
    var errorDescription: String? {
        switch self {
        case .timeout: return "超时"
        case .refused: return "连接被拒绝"
        case .rejected: return "密钥错误或被拒绝（对端静默断开）"
        case .parse: return "解析失败"
        case .invalidURL: return "请输入 HTTPS 地址（开发环境允许 localhost/127.0.0.1 HTTP）"
        case .missingSecret: return "未找到密钥"
        case .keychain(let code): return "钥匙串错误：\(code)"
        case .transport(let message): return message
        }
    }
}
