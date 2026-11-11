import Foundation

/// 可在设置中选择的本地 VLM（参考 Eira 的 ModelRouter）。全部为视觉语言模型：抽取需要直接看截图。
public struct LocalModelOption: Sendable, Equatable, Identifiable {
    public let displayName: String
    /// Hugging Face Hub 标识，即配置中的 `extraction.modelTag`。
    public let tag: String
    /// 约需下载的大小。
    public let diskGB: Int
    /// 加载后的常驻内存（含推理缓冲）。已验证的模型取 amai-extraction eval 实测峰值，其余沿用 Eira 的估计。
    public let memoryGB: Int
    /// 是否已用 Amai 的抽取提示词在真实录屏上验证过。未验证的模型可以手动选择，但不会被推荐。
    public let verified: Bool

    public var id: String { tag }
}

public enum LocalModelCatalog {
    public static let all: [LocalModelOption] = [
        LocalModelOption(displayName: "Gemma 4 E2B", tag: "mlx-community/gemma-4-e2b-it-4bit", diskGB: 2, memoryGB: 3, verified: false),
        // E4B：2026-11-11 视觉部分修复后实测抽取峰值 7.7 GB（此前看不到截图时为 6.3 GB）。
        LocalModelOption(displayName: "Gemma 4 E4B", tag: LocalInferenceBackend.defaultModelTag, diskGB: 5, memoryGB: 8, verified: true),
        LocalModelOption(displayName: "Gemma 3 12B", tag: "mlx-community/gemma-3-12b-it-qat-4bit", diskGB: 8, memoryGB: 10, verified: false),
        LocalModelOption(displayName: "Gemma 4 26B", tag: LocalInferenceBackend.largeModelTag, diskGB: 16, memoryGB: 18, verified: true),
    ]

    public static func option(for tag: String) -> LocalModelOption? {
        all.first { $0.tag == tag }
    }

    /// 本机物理内存（GB，取整）。
    public static let machineMemoryGB = Int((Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824).rounded())

    /// 推荐常驻内存不超过本机内存 1/3 的最大已验证模型：Amai 长期在后台运行，模型要给其他应用留出余量。
    /// 没有满足条件的已验证模型时，推荐内存占用最小的模型。
    public static func recommended(forMemoryGB memoryGB: Int = machineMemoryGB) -> LocalModelOption {
        all.filter { $0.verified && $0.memoryGB * 3 <= memoryGB }.max { $0.memoryGB < $1.memoryGB }
            ?? all.min { $0.memoryGB < $1.memoryGB }!
    }
}
