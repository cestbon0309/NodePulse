import Foundation
import Network

struct DirectClient {
    func fetch(_ endpoint: Endpoint, secret: String) async throws -> [NodeSnapshot] {
        guard case let .direct(host, port) = endpoint.kind, port > 0,
              let nwPort = NWEndpoint.Port(rawValue: port) else { throw ProbeError.refused }
        let rid = (0..<16).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max)) }.joined()
        let request = try JSONSerialization.data(withJSONObject: ["op": "get", "ts": Int(Date().timeIntervalSince1970), "rid": rid])
        let crypto = ProbeCrypto(secret: secret)
        let operation = DirectOperation(host: host, port: nwPort, frame: try crypto.seal(json: request))
        let response = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { operation.start($0) }
        } onCancel: { operation.cancel() }
        return try Self.decodeResponse(crypto.open(frame: response), requestID: rid)
    }
    static func decodeResponse(_ data: Data, requestID: String) throws -> [NodeSnapshot] {
        guard let response = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              response["rid"] as? String == requestID else { throw ProbeError.transport("响应校验失败") }
        return try ProbeResponse.decode(data)
    }
}

final class DirectOperation: @unchecked Sendable {
    private let queue = DispatchQueue(label: "nodepulse.direct.\(UUID())")
    private let connection: NWConnection
    private let frame: Data
    private var continuation: CheckedContinuation<Data, Error>?
    private var finished = false
    private var timer: DispatchWorkItem?
    init(host: String, port: NWEndpoint.Port, frame: Data) {
        connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: .tcp)
        self.frame = frame
    }
    func start(_ continuation: CheckedContinuation<Data, Error>) {
        queue.async {
            if self.finished { continuation.resume(throwing: CancellationError()); return }
            self.continuation = continuation
            let timer = DispatchWorkItem { self.finish(.failure(ProbeError.timeout)) }
            self.timer = timer
            self.queue.asyncAfter(deadline: .now() + 6, execute: timer)
            self.connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    self.connection.send(content: self.frame, completion: .contentProcessed { error in
                        if let error { self.finish(.failure(Self.map(error))); return }
                        self.read(4) { header in
                            do {
                                let count = try ProbeCrypto.length(header)
                                self.read(count + 28) { self.finish(.success(header + $0)) }
                            } catch { self.finish(.failure(error)) }
                        }
                    })
                case .failed(let error): self.finish(.failure(Self.map(error)))
                default: break
                }
            }
            self.connection.start(queue: self.queue)
        }
    }
    func cancel() { queue.async { self.finish(.failure(CancellationError())) } }
    private func read(_ count: Int, accumulated: Data = Data(), completion: @escaping (Data) -> Void) {
        guard !finished else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: count - accumulated.count) { data, _, closed, error in
            if let error { self.finish(.failure(Self.map(error))); return }
            let result = accumulated + (data ?? Data())
            if result.count == count { completion(result) }
            else if closed { self.finish(.failure(ProbeError.rejected)) }
            else { self.read(count, accumulated: result, completion: completion) }
        }
    }
    private func finish(_ result: Result<Data, Error>) {
        guard !finished else { return }
        finished = true
        timer?.cancel(); timer = nil
        connection.stateUpdateHandler = nil
        connection.cancel()
        continuation?.resume(with: result); continuation = nil
    }
    private static func map(_ error: NWError) -> Error {
        if case .posix(let code) = error {
            if code == .ECONNREFUSED { return ProbeError.refused }
            if code == .ETIMEDOUT { return ProbeError.timeout }
            if code == .ECONNRESET || code == .EPIPE { return ProbeError.rejected }
        }
        return ProbeError.transport("连接失败：\(error.localizedDescription)")
    }
}

struct HTTPSClient {
    static func nodesURL(_ input: String) throws -> URL {
        try apiURL(input, path: "/api/nodes")
    }
    static func apiURL(_ input: String, path suffix: String) throws -> URL {
        guard var parts = URLComponents(string: input), let host = parts.host,
              parts.user == nil, parts.password == nil,
              parts.scheme?.lowercased() == "https" ||
                (parts.scheme?.lowercased() == "http" && ["localhost", "127.0.0.1"].contains(host.lowercased()))
        else { throw ProbeError.invalidURL }
        var path = parts.path
        while path.hasSuffix("/") { path.removeLast() }
        if !path.hasSuffix(suffix) { path += suffix }
        parts.path = path; parts.query = nil; parts.fragment = nil
        guard let url = parts.url else { throw ProbeError.invalidURL }
        return url
    }
    func fetch(_ endpoint: Endpoint, secret: String) async throws -> [NodeSnapshot] {
        guard case let .https(input) = endpoint.kind else { throw ProbeError.invalidURL }
        var request = URLRequest(url: try Self.nodesURL(input))
        request.timeoutInterval = 8
        request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        return try ProbeResponse.decode(await Self.data(for: request))
    }
    static func data(for request: URLRequest) async throws -> Data {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForResource = 8
        let session = URLSession(configuration: config, delegate: NoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else { throw ProbeError.parse }
            if response.statusCode == 404 { throw ProbeError.transport("密钥错误或路径不对") }
            guard response.statusCode == 200 else { throw ProbeError.transport("HTTP 错误：\(response.statusCode)") }
            return data
        } catch let error as URLError {
            if error.code == .timedOut { throw ProbeError.timeout }
            if error.code == .cannotConnectToHost { throw ProbeError.refused }
            throw ProbeError.transport("连接失败：\(error.localizedDescription)")
        }
    }
}

private final class NoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

struct GroupClient {
    static func relayURL(_ input: String) throws -> URL { try HTTPSClient.apiURL(input, path: "/api/relay") }
    func fetch(_ endpoint: Endpoint, token: String, groupSecret: String) async throws -> ProbeFetch {
        let group = try GroupCrypto(secret: groupSecret)
        let request = try group.getRequest()
        let transport = ProbeCrypto(secret: token)
        let frame = try transport.seal(json: request.json)
        let response: Data
        switch endpoint.kind {
        case let .groupTCP(host, port):
            guard port > 0, let nwPort = NWEndpoint.Port(rawValue: port) else { throw ProbeError.refused }
            let operation = DirectOperation(host: host, port: nwPort, frame: frame)
            response = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { operation.start($0) }
            } onCancel: { operation.cancel() }
        case let .groupHTTPS(input):
            var request = URLRequest(url: try Self.relayURL(input))
            request.httpMethod = "POST"; request.httpBody = frame; request.timeoutInterval = 8
            request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            request.setValue(String(frame.count), forHTTPHeaderField: "Content-Length")
            response = try await HTTPSClient.data(for: request)
        default: throw ProbeError.parse
        }
        return try group.decodeResponse(transport.open(frame: response), requestID: request.rid)
    }
}

func fetchProbe(_ endpoint: Endpoint, secret: String, groupSecret: String? = nil) async throws -> ProbeFetch {
    switch endpoint.kind {
    case .direct: return ProbeFetch(snapshots: try await DirectClient().fetch(endpoint, secret: secret))
    case .https: return ProbeFetch(snapshots: try await HTTPSClient().fetch(endpoint, secret: secret))
    case .groupTCP, .groupHTTPS:
        guard let groupSecret, !groupSecret.isEmpty else { throw ProbeError.missingSecret }
        return try await GroupClient().fetch(endpoint, token: secret, groupSecret: groupSecret)
    }
}
