import CryptoKit
import Foundation

struct PairCrypto {
    static func commit(_ publicKey: Data) -> Data {
        Data(SHA512.hash(data: Data("npulse-pair-commit".utf8) + publicKey).prefix(32))
    }
    static func keys(privateKey: Curve25519.KeyAgreement.PrivateKey, peer: Data, psk: Data? = nil) throws -> Data {
        let shared = try privateKey.sharedSecretFromKeyAgreement(with: Curve25519.KeyAgreement.PublicKey(rawRepresentation: peer))
        return shared.withUnsafeBytes { bytes in
            Data(SHA512.hash(data: Data("npulse-pair".utf8) + Data(bytes) + privateKey.publicKey.rawRepresentation + peer + (psk ?? Data())))
        }
    }
    static func sas(_ keys: Data) -> Data { Data(SHA512.hash(data: Data("npulse-pair-sas".utf8) + keys).prefix(16)) }
    static func code(_ sas: Data) -> String {
        let value = sas.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) } % 1_000_000
        let digits = String(format: "%06u", value)
        return String(digits.prefix(3)) + " " + String(digits.suffix(3))
    }
    static func art(_ sas: Data) -> String {
        let symbols = Array(" .o+=*BOX@%&#/^SE")
        var cells = Array(repeating: Array(repeating: 0, count: 17), count: 9)
        var x = 8, y = 4
        for byte in sas {
            for bit in stride(from: 0, to: 8, by: 2) {
                x = max(0, min(16, x + (byte & (1 << bit) == 0 ? -1 : 1)))
                y = max(0, min(8, y + (byte & (2 << bit) == 0 ? -1 : 1)))
                cells[y][x] = min(14, cells[y][x] + 1)
            }
        }
        cells[4][8] = 15; cells[y][x] = 16
        return "+---[NodePulse]---+\n" + cells.map { "|" + String($0.map { symbols[$0] }) + "|\n" }.joined() + "+-----[PAIR]------+\n"
    }
}

enum PairError: LocalizedError {
    case rejected, timeout, connection, handshake
    var errorDescription: String? {
        switch self {
        case .rejected: return L10n.text("配对已被拒绝，密钥未保存。请在服务器上重新运行 pair 后重试。")
        case .timeout: return L10n.text("配对超时。请在服务器上重新开启配对，并在 30 秒内核对图案和数字。")
        case .connection: return L10n.text("配对连接失败或已断开。请确认地址、端口、防火墙，以及探针正在运行 -P。")
        case .handshake: return L10n.text("配对握手校验失败，未保存密钥。请勿忽略图案或数字不一致。")
        }
    }
    static func transport(_ error: Error) -> Error {
        if error is CancellationError || error is PairError { return error }
        return error.localizedDescription.localizedCaseInsensitiveContains(L10n.text("超时")) ? Self.timeout : Self.connection
    }
}
