import AmaiCore
import Foundation
import HuggingFace
import MLXHuggingFace
import MLXLMCommon

/// 由用户在设置中明确发起的模型下载（参考 Eira 的 MLXClient.install）。只下载权重与分词器文件到 Hub 缓存，
/// 不加载模型；只连接 Hugging Face，不发送任何用户数据。Amai 从不在后台自动下载。
public enum LocalModelDownloader {
    public enum Event: Sendable, Equatable {
        /// 正在解析文件列表，或文件已在缓存中。
        case preparing
        case downloading(fraction: Double)
        case finished
    }

    /// 与 mlx-swift-lm 加载模型时所需的文件一致。
    private static let patterns = ["*.safetensors", "*.json", "*.jinja"]

    /// 取消：终止对返回流的迭代即可，已下载的文件留在缓存中，下次从断点继续。
    public static func download(tag: String) -> AsyncThrowingStream<Event, Error> {
        let (stream, continuation) = AsyncThrowingStream<Event, Error>.makeStream()
        let log = AmaiLog.logger("extraction.download")
        let total = TotalBytes()
        // 进度按磁盘字节数计算：HubClient 的 fractionCompleted 不反映实际写入（Eira 实测）。
        // 断点续传时，已在缓存中的部分也计入已下载。
        let baseline = progressBytes() - directorySize(modelDirectory(tag))

        let poll = Task.detached {
            while !Task.isCancelled {
                if let bytes = total.value, bytes > 0 {
                    let fraction = min(1, Double(max(0, progressBytes() - baseline)) / Double(bytes))
                    continuation.yield(.downloading(fraction: fraction))
                } else {
                    continuation.yield(.preparing)
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        let work = Task {
            do {
                log.info("model download started: \(tag, privacy: .public)")
                _ = try await #hubDownloader().download(
                    id: tag, revision: "main", matching: patterns, useLatest: false
                ) { progress in
                    if progress.totalUnitCount > 0 { total.value = progress.totalUnitCount }
                }
                poll.cancel()
                guard LocalInferenceBackend.isInstalled(tag: tag) else {
                    throw ModelProviderError.loadFailed("\(tag): 下载完成但权重不完整")
                }
                log.info("model download finished: \(tag, privacy: .public)")
                continuation.yield(.finished)
                continuation.finish()
            } catch is CancellationError {
                poll.cancel()
                log.info("model download cancelled: \(tag, privacy: .public)")
                continuation.finish()
            } catch {
                poll.cancel()
                log.error("model download failed: \(String(describing: error), privacy: .public)")
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in
            poll.cancel()
            work.cancel()
        }
        return stream
    }

    // MARK: - Byte counting

    private static func modelDirectory(_ tag: String) -> URL {
        LocalInferenceBackend.hubCacheURL.appendingPathComponent("models--" + tag.replacingOccurrences(of: "/", with: "--"))
    }

    /// Hub 缓存加上 URLSession 的临时下载文件：分片在写完前先落在系统临时目录，完成后才移入缓存。
    private static func progressBytes() -> Int64 {
        directorySize(LocalInferenceBackend.hubCacheURL) + temporaryDownloadBytes()
    }

    private static func temporaryDownloadBytes() -> Int64 {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let entries = (try? FileManager.default.contentsOfDirectory(at: tmp, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return entries
            .filter { $0.lastPathComponent.hasPrefix("CFNetworkDownload_") && $0.pathExtension == "tmp" }
            .reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) }
    }

    private static func directorySize(_ url: URL) -> Int64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else {
            return 0
        }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            let values = try? file.resourceValues(forKeys: Set(keys))
            if values?.isRegularFile == true { total += Int64(values?.totalFileAllocatedSize ?? 0) }
        }
        return total
    }
}

/// 下载总字节数，由 HubClient 的进度回调写入一次，轮询任务读取。
private final class TotalBytes: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: Int64?
    var value: Int64? {
        get { lock.withLock { bytes } }
        set { lock.withLock { bytes = newValue } }
    }
}
