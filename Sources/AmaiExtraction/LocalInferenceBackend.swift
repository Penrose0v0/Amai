import Foundation

/// 嵌入式本地推理后端的常量与模型安装检查。
public enum LocalInferenceBackend {
    public static let name = "mlx-swift-lm"

    /// 默认模型：后台常驻友好（约 5 GB 内存）。
    public static let defaultModelTag = "mlx-community/gemma-4-e4b-it-4bit"
    /// 可选的高质量模型（约 18 GB 内存）。
    public static let largeModelTag = "mlx-community/gemma-4-26b-a4b-it-4bit"

    /// HuggingFace Hub 本地缓存根目录。
    public static var hubCacheURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/huggingface/hub")
    }

    /// 权重是否完整在本地（参考 Eira 的判断：单个 model.safetensors，
    /// 或 index 中列出的全部分片都存在且非空）。Amai 从不在后台自动下载模型。
    public static func isInstalled(tag: String, hubCache: URL = hubCacheURL) -> Bool {
        let dirName = "models--" + tag.replacingOccurrences(of: "/", with: "--")
        let snapshots = hubCache.appendingPathComponent(dirName).appendingPathComponent("snapshots")
        guard let revisions = try? FileManager.default.contentsOfDirectory(atPath: snapshots.path) else {
            return false
        }
        return revisions.contains { hasWeights(in: snapshots.appendingPathComponent($0)) }
    }

    private static func hasWeights(in dir: URL) -> Bool {
        if size(dir.appendingPathComponent("model.safetensors")) > 0 { return true }
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("model.safetensors.index.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let map = json["weight_map"] as? [String: String]
        else { return false }
        return Set(map.values).allSatisfy { size(dir.appendingPathComponent($0)) > 0 }
    }

    private static func size(_ url: URL) -> Int64 {
        // 分片通常是指向 blobs 的符号链接，取解析后的文件大小。
        let resolved = url.resolvingSymlinksInPath()
        let attrs = try? FileManager.default.attributesOfItem(atPath: resolved.path)
        return (attrs?[.size] as? NSNumber)?.int64Value ?? 0
    }
}
