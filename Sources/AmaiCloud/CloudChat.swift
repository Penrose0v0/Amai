import AmaiCore
import Foundation

// 云端 Provider 的对话实现（流式、多轮、工具调用）共用的部分：SSE 读取与错误映射。
// 各 Provider 把统一的 `ChatRequest` 转成自己的线上格式，把流式事件转回 `ChatEvent`。

/// 一条 Server-Sent Event。
struct ServerSentEvent: Sendable, Equatable {
    var event: String?
    var data: String
}

enum SSE {
    /// 发出请求并逐条读取 SSE。非 2xx 时读完响应体交给 `mapError`。
    /// 流式请求不自动重试：重试会让已经显示的文字重复出现，交给用户重发。
    static func events(
        _ request: URLRequest, session: URLSession,
        mapError: @escaping @Sendable (Int, Data) -> CloudError
    ) -> AsyncThrowingStream<ServerSentEvent, Error> {
        let (stream, continuation) = AsyncThrowingStream<ServerSentEvent, Error>.makeStream()
        let task = Task {
            do {
                let (bytes, response) = try await session.bytes(for: request)
                guard let http = response as? HTTPURLResponse else { throw CloudError.invalidResponse }
                guard (200..<300).contains(http.statusCode) else {
                    var data = Data()
                    for try await byte in bytes { data.append(byte) }
                    throw mapError(http.statusCode, data)
                }
                var event: String?
                for try await line in bytes.lines {
                    // `bytes.lines` 跳过空行，所以不能靠空行分隔事件：每个 data 行就是一条事件。
                    if line.hasPrefix("event:") {
                        event = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
                    } else if line.hasPrefix("data:") {
                        let data = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        continuation.yield(ServerSentEvent(event: event, data: data))
                        event = nil
                    }
                }
                continuation.finish()
            } catch let error as CloudError {
                continuation.finish(throwing: error)
            } catch is CancellationError {
                continuation.finish(throwing: CancellationError())
            } catch let error as URLError {
                if error.code == .cancelled {
                    continuation.finish(throwing: CancellationError())
                } else {
                    continuation.finish(throwing: CloudError.network(
                        error.code == .timedOut ? String(localized: "请求超时") : "\(error.code.rawValue)"
                    ))
                }
            } catch {
                continuation.finish(throwing: CloudError.network(String(localized: "响应流中断")))
            }
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    static func json(_ data: String) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(data.utf8))) as? [String: Any]
    }
}

enum CloudChat {
    /// 把一个"逐条读取并产出 ChatEvent"的过程包成流，统一处理取消与错误。
    static func stream(
        _ body: @escaping @Sendable (AsyncThrowingStream<ChatEvent, Error>.Continuation) async throws -> Void
    ) -> AsyncThrowingStream<ChatEvent, Error> {
        let (stream, continuation) = AsyncThrowingStream<ChatEvent, Error>.makeStream()
        let task = Task {
            do {
                try await body(continuation)
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    static func jsonString(_ object: Any) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    static func schema(_ tool: ChatToolSpec) -> Any {
        (try? JSONSerialization.jsonObject(with: Data(tool.parametersJSON.utf8)))
            ?? ["type": "object", "properties": [String: Any]()]
    }

    static func dataURL(_ image: ChatImage) -> String {
        "data:image/jpeg;base64," + image.jpeg.base64EncodedString()
    }
}
