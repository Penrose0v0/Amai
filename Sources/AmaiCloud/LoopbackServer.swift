import Foundation
import Network

/// 只监听 127.0.0.1 的一次性 OAuth 回调服务（SIWC 要求回调地址为 `http://127.0.0.1:<port>/auth/callback`，
/// 不能用 localhost；必须在打开浏览器之前开始监听）。收到一次回调后自动关闭。
public final class LoopbackServer: @unchecked Sendable {
    public let path: String
    private let listener: NWListener
    private let queue = DispatchQueue(label: "com.amai.loopback")
    private let lock = NSLock()
    private var continuation: CheckedContinuation<[String: String], Error>?
    private var pending: Result<[String: String], Error>?
    private var finished = false

    /// 端口被占用时改用系统分配的端口（只有端口允许变化）。
    public static func start(preferredPort: UInt16, path: String) async throws -> LoopbackServer {
        if let server = try? await LoopbackServer(port: preferredPort, path: path) {
            return server
        }
        return try await LoopbackServer(port: 0, path: path)
    }

    private init(port: UInt16, path: String) async throws {
        self.path = path
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port) ?? .any)
        listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in self?.handle(connection) }
        try await withCheckedThrowingContinuation { (ready: CheckedContinuation<Void, Error>) in
            let once = OnceFlag()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if once.fire() { ready.resume() }
                case .failed(let error):
                    if once.fire() { ready.resume(throwing: error) }
                case .cancelled:
                    if once.fire() { ready.resume(throwing: CloudError.local(String(localized: "回调服务已取消"))) }
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    public var port: UInt16 { listener.port?.rawValue ?? 0 }
    public var redirectURI: String { "http://127.0.0.1:\(port)\(path)" }

    /// 等待浏览器回调，返回查询参数。超时或被取消时抛错。
    public func waitForCallback(timeout: TimeInterval) async throws -> [String: String] {
        let timer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            self?.finish(.failure(CloudError.signInRequired(String(localized: "等待浏览器授权超时"))))
        }
        defer { timer.cancel() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { c in
                lock.lock()
                if let pending {
                    lock.unlock()
                    c.resume(with: pending)
                } else {
                    continuation = c
                    lock.unlock()
                }
            }
        } onCancel: { [weak self] in
            self?.finish(.failure(CancellationError()))
        }
    }

    public func stop() {
        listener.cancel()
    }

    private func finish(_ result: Result<[String: String], Error>) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let c = continuation
        continuation = nil
        if c == nil { pending = result }
        lock.unlock()
        c?.resume(with: result)
        listener.cancel()
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
            guard let self else { return }
            let request = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
            let target = request.split(separator: "\r\n").first?.split(separator: " ").dropFirst().first.map(String.init) ?? ""
            let components = URLComponents(string: "http://127.0.0.1\(target)")
            let matches = components?.path == self.path
            let body = matches
                ? String(localized: "<html><meta charset=utf-8><body style='font-family:-apple-system;padding:40px'><h2>已完成授权</h2><p>可以关闭此页面，回到 Amai。</p></body></html>")
                : "<html><body>Not found</body></html>"
            let response = "HTTP/1.1 \(matches ? "200 OK" : "404 Not Found")\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            if matches {
                var query: [String: String] = [:]
                for item in components?.queryItems ?? [] { query[item.name] = item.value ?? "" }
                self.finish(.success(query))
            }
        }
    }
}

private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    func fire() -> Bool { lock.withLock { defer { fired = true }; return !fired } }
}
