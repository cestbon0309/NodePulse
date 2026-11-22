import Foundation
import Network

struct PairInvite: Identifiable {
    let id = UUID()
    let host: String
    let port: UInt16
    let token: String?
    let code: String?
    let psk: Data
    var isRelay: Bool { token != nil }
    var address: String { host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)" }
    static func validHost(_ text: String) -> Bool {
        !text.isEmpty && text.utf8.count <= 253 && !text.contains(where: { $0.isWhitespace || $0.isNewline || "/\\@?#%".contains($0) }) &&
        (!text.contains(":") || IPv6Address(text) != nil)
    }
    static func address(_ text: String) throws -> (String, UInt16) {
        guard let colon = text.lastIndex(of: ":"), let port = UInt16(text[text.index(after: colon)...]), port > 0 else { throw PairError.handshake }
        let raw = String(text[..<colon])
        let host = raw.hasPrefix("[") && raw.hasSuffix("]") ? String(raw.dropFirst().dropLast()) : raw
        guard validHost(host), !host.contains(":") || raw.hasPrefix("[") else { throw PairError.handshake }
        return (host, port)
    }
    static func formattedCode(_ text: String) -> String {
        let normalized = text.uppercased().map { $0 == "O" ? Character("0") : ($0 == "I" || $0 == "L" ? Character("1") : $0) }.filter { "0123456789ABCDEFGHJKMNPQRSTVWXYZ".contains($0) }.prefix(8)
        let raw = String(normalized)
        return raw.count > 4 ? String(raw.prefix(4)) + "-" + String(raw.dropFirst(4)) : raw
    }
    init(url: URL) throws {
        guard url.scheme?.lowercased() == "nodepulse", url.host?.lowercased() == "pair", url.user == nil, url.password == nil,
              url.port == nil, url.fragment == nil, ["", "/"].contains(url.path),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw PairError.handshake }
        var fields: [String: String] = [:]
        for item in components.queryItems ?? [] {
            guard fields[item.name] == nil, let value = item.value else { throw PairError.handshake }
            fields[item.name] = value
        }
        guard fields["v"] == "1", let raw = fields["s"], raw.utf8.count == 22,
              raw.allSatisfy({ "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-".contains($0) }),
              let psk = Data(base64Encoded: raw.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") + "=="), psk.count == 16 else { throw PairError.handshake }
        self.psk = psk
        if let relay = fields["r"] {
            guard fields["h"] == nil, fields["p"] == nil, let token = fields["t"], !token.isEmpty, token.utf8.count <= 1024,
                  let code = fields["c"], code.filter({ $0 != "-" }).count == 8,
                  code.uppercased().allSatisfy({ "0123456789ABCDEFGHJKMNPQRSTVWXYZ-OIL".contains($0) }) else { throw PairError.handshake }
            (host, port) = try Self.address(relay); self.token = token; self.code = Self.formattedCode(code)
        } else {
            guard fields["t"] == nil, fields["c"] == nil, let host = fields["h"], Self.validHost(host),
                  let text = fields["p"], let port = UInt16(text), port > 0 else { throw PairError.handshake }
            self.host = host; self.port = port; token = nil; code = nil
        }
    }
}
