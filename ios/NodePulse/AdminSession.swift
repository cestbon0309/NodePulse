import CryptoKit
import Foundation
import Network

final class AdminConnection: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "nodepulse.admin.transport.\(UUID())")
    init(host: String, port: UInt16) throws {
        guard let port = NWEndpoint.Port(rawValue: port), port.rawValue > 0 else { throw AdminError.message("接入点端口无效") }
        connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: .tcp)
    }
    func open() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                queue.async {
                    var finished = false
                    let complete: (Error?) -> Void = { error in
                        guard !finished else { return }; finished = true
                        self.connection.stateUpdateHandler = nil
                        if let error { self.connection.cancel(); continuation.resume(throwing: error) }
                        else { continuation.resume() }
                    }
                    self.connection.stateUpdateHandler = { state in
                        switch state {
                        case .ready: complete(nil)
                        case .failed: complete(AdminError.message("节点离线或连接失败"))
                        case .cancelled: complete(CancellationError())
                        default: break
                        }
                    }
                    self.queue.asyncAfter(deadline: .now() + 10) { complete(AdminError.message("连接超时，节点可能离线")) }
                    self.connection.start(queue: self.queue)
                }
            }
        } onCancel: { self.cancel() }
    }
    func cancel() { connection.cancel() }
    func send(_ data: Data) async throws {
        try Task.checkCancellation()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                self.connection.send(content: data, completion: .contentProcessed { error in
                    if error != nil { continuation.resume(throwing: AdminError.disconnected) }
                    else { continuation.resume() }
                })
            }
        }
    }
    func read(_ count: Int) async throws -> Data {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    var finished = false
                    let timer: DispatchWorkItem
                    let complete: (Result<Data, Error>) -> Void = { result in
                        guard !finished else { return }; finished = true
                        continuation.resume(with: result)
                    }
                    timer = DispatchWorkItem { self.connection.cancel(); complete(.failure(AdminError.message("管理连接超时"))) }
                    self.queue.asyncAfter(deadline: .now() + 45, execute: timer)
                    func receive(_ collected: Data) {
                        self.connection.receive(minimumIncompleteLength: 1, maximumLength: count - collected.count) { data, _, closed, error in
                            guard !finished else { return }
                            let result = collected + (data ?? Data())
                            if result.count == count { timer.cancel(); complete(.success(result)) }
                            else if error != nil || closed { timer.cancel(); complete(.failure(AdminError.disconnected)) }
                            else { receive(result) }
                        }
                    }
                    receive(Data())
                }
            }
        } onCancel: { self.cancel() }
    }
    func readFrame(overhead: Int, limit: Int = 262144) async throws -> Data {
        let header = try await read(4)
        let n = try ProbeCrypto.length(header)
        guard n <= limit else { throw AdminError.disconnected }
        return header + (try await read(n + overhead))
    }
}

enum AdminEvent: Sendable {
    case output(pty: Int, data: Data)
    case exit(pty: Int, code: Int)
}

actor AdminSession {
    nonisolated let events: AsyncStream<AdminEvent>
    private let eventSink: AsyncStream<AdminEvent>.Continuation
    private let channel: AdminConnection
    private var tx: AdminCipher
    private var rx: AdminCipher
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var timeouts: [Int: Task<Void, Never>] = [:]
    private var reader: Task<Void, Never>?
    private var pinger: Task<Void, Never>?
    private var sending: Task<Void, Error>?
    private var closed = false

    private init(channel: AdminConnection, keys: Data) {
        self.channel = channel; tx = AdminCipher(key: Data(keys.prefix(32))); rx = AdminCipher(key: Data(keys.suffix(32)))
        let stream = AsyncStream<AdminEvent>.makeStream(bufferingPolicy: .bufferingOldest(128))
        events = stream.stream; eventSink = stream.continuation
    }
    static func supports(_ kind: Endpoint.Kind) -> Bool {
        switch kind { case .direct, .groupTCP: return true; default: return false }
    }
    static func connect(endpoint: Endpoint, node: String, secret: String, groupSecret: String? = nil,
                        signing: Curve25519.Signing.PrivateKey) async throws -> AdminSession {
        let host: String, port: UInt16, relay: Bool
        switch endpoint.kind {
        case .direct(let h, let p): host = h; port = p; relay = false
        case .groupTCP(let h, let p): host = h; port = p; relay = true
        default: throw AdminError.message("HTTPS 接入点不支持管理，请使用直连或 TCP 中继")
        }
        let channel = try AdminConnection(host: host, port: port)
        do {
            try await channel.open()
            if relay {
                guard let groupSecret else { throw ProbeError.missingSecret }
                let group = try GroupCrypto(secret: groupSecret), rid = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
                let slot = group.slot(for: node), ts = Int(Date().timeIntervalSince1970)
                let signature = try group.signingKey.signature(for: Data("npulse-gconnect\n\(group.gid)\n\(slot)\n\(ts)\n\(rid)".utf8))
                let json = try JSONSerialization.data(withJSONObject: ["op": "gconnect", "ts": ts, "rid": rid, "gid": group.gid, "slot": slot, "sig": GroupCrypto.hex(signature)])
                let outer = ProbeCrypto(secret: secret)
                try await channel.send(outer.seal(json: json))
                let response = try object(outer.open(frame: await channel.readFrame(overhead: 28)))
                guard response["ok"] as? Bool == true else { throw AdminError.message(response["err"] as? String == "offline" ? "节点离线，探针尚未连接中继" : "中继连接被拒绝") }
            }
            let ephemeral = Curve25519.KeyAgreement.PrivateKey()
            let epk = GroupCrypto.hex(ephemeral.publicKey.rawRepresentation)
            let rid = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(), ts = Int(Date().timeIntervalSince1970)
            let signature = try signing.signature(for: Data("npulse-admin-hello\n\(node)\n\(ts)\n\(rid)\n\(epk)".utf8))
            let hello = try JSONSerialization.data(withJSONObject: ["op": "admin", "v": 1, "node": node, "ts": ts, "rid": rid,
                "epk": epk, "apk": GroupCrypto.hex(signing.publicKey.rawRepresentation), "sig": GroupCrypto.hex(signature)])
            let outer = ProbeCrypto(secret: secret)
            try await channel.send(relay ? AdminCrypto.length(hello.count) + hello : outer.seal(json: hello))
            let frame = try await channel.readFrame(overhead: relay ? 0 : 28)
            let ack = try object(relay ? Data(frame.dropFirst(4)) : outer.open(frame: frame))
            let peer = try AdminCrypto.verifyACK(ack, secret: relay ? groupSecret! : secret, rid: rid, client: epk)
            let session = AdminSession(channel: channel, keys: try AdminCrypto.keys(ephemeral: ephemeral, peer: peer))
            await session.start()
            return session
        } catch {
            channel.cancel()
            if error is CancellationError { throw error }
            if let admin = error as? AdminError, admin.localizedDescription.contains("离线") { throw admin }
            throw AdminError.handshake
        }
    }
    private static func object(_ data: Data) throws -> [String: Any] {
        guard !data.contains(0), let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw AdminError.disconnected }
        return json
    }
    private func start() {
        reader = Task { [weak self, channel] in
            do {
                while !Task.isCancelled {
                    let frame = try await channel.readFrame(overhead: 16, limit: 131072)
                    try await self?.consume(frame)
                }
            } catch { await self?.close(error) }
        }
        pinger = Task { [weak self] in
            do {
                while !Task.isCancelled {
                    try await Task.sleep(for: .seconds(30))
                    _ = try await self?.request("ping")
                }
            } catch { await self?.close(error) }
        }
    }
    func request(_ type: String, _ fields: [String: Any] = [:]) async throws -> [String: Any] {
        guard !closed else { throw AdminError.disconnected }
        try Task.checkCancellation()
        let id = nextID; nextID += 1
        var json = fields; json["t"] = type; json["id"] = id
        let frame = try tx.seal(JSONSerialization.data(withJSONObject: json, options: [.withoutEscapingSlashes]))
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending[id] = continuation
                timeouts[id] = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(30)); await self?.close(AdminError.message("管理请求超时")) } catch {}
                }
                let send = enqueue(frame)
                Task {
                    do { try await send.value }
                    catch { close(error) }
                }
            }
        } onCancel: { Task { await self.cancelRequest(id) } }
    }
    private func enqueue(_ frame: Data) -> Task<Void, Error> {
        let previous = sending
        let task = Task { [channel] in
            if let previous { try await previous.value }
            try await channel.send(frame)
        }
        sending = task
        return task
    }
    func input(pty: Int, data: Data) async throws {
        guard !closed else { throw AdminError.disconnected }
        guard data.count <= 65536 else { throw AdminError.message("终端输入过大") }
        let json = try JSONSerialization.data(withJSONObject: ["t": "pty_in", "pty": pty, "data": data.base64EncodedString()])
        do { try await enqueue(tx.seal(json)).value }
        catch { close(error); throw error }
    }
    private func cancelRequest(_ id: Int) {
        timeouts.removeValue(forKey: id)?.cancel()
        pending.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }
    private func consume(_ frame: Data) throws {
        let json = try Self.object(rx.open(frame))
        if let type = json["t"] as? String {
            guard let pty = json["pty"] as? Int else { throw AdminError.disconnected }
            let event: AdminEvent
            if type == "pty_out", let text = json["data"] as? String, let data = Data(base64Encoded: text) { event = .output(pty: pty, data: data) }
            else if type == "pty_exit", let code = json["code"] as? Int { event = .exit(pty: pty, code: code) }
            else { throw AdminError.disconnected }
            if case .dropped = eventSink.yield(event) { throw AdminError.message("终端输出过快，请重新连接") }
        } else {
            guard let id = json["id"] as? Int, let ok = json["ok"] as? Bool else { throw AdminError.disconnected }
            timeouts.removeValue(forKey: id)?.cancel()
            if ok { pending.removeValue(forKey: id)?.resume(returning: json) }
            else { pending.removeValue(forKey: id)?.resume(throwing: AdminError.message("远程操作失败：\(json["err"] as? String ?? "未知错误")")) }
        }
    }
    func close(_ error: Error = AdminError.disconnected) {
        guard !closed else { return }; closed = true
        reader?.cancel(); pinger?.cancel(); channel.cancel(); eventSink.finish()
        for task in timeouts.values { task.cancel() }; timeouts.removeAll()
        for continuation in pending.values { continuation.resume(throwing: error) }; pending.removeAll()
    }
    deinit { channel.cancel(); reader?.cancel(); pinger?.cancel(); eventSink.finish() }
}
