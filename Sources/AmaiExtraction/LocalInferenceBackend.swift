import Foundation
import MLXLMCommon

/// 嵌入式本地推理后端的常量。`MLXModelProvider` 在 M2 实现；
/// 此文件在 M0 的作用是确认 MLX 依赖链接通过。
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
}
