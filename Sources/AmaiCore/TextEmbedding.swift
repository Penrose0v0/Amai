import Foundation

/// 把文字变成向量，供记忆的语义检索使用。实现可替换（本地 MLX 模型、今后的其他后端）；
/// 记忆层只面向这个契约，没有可用的实现时检索退回纯关键词。
public protocol TextEmbedder: Sendable {
    /// 模型标识。向量按它分开存放：换模型后旧向量不再参与比较，而是重新计算。
    var identifier: String { get }
    /// 现在是否可用（模型已在本地）。不可用时调用方不应等待，直接走关键词检索。
    var isAvailable: Bool { get }
    /// 余弦相似度的有效区间：下界是"毫不相关的两段文字"的典型值，上界是"明确相关"的典型值。
    /// 各模型的相似度刻度差别很大，检索时按这个区间换算成 0…1 的得分，门槛才有意义。
    var similarityRange: ClosedRange<Float> { get }

    /// 返回与输入一一对应的单位向量。`kind` 区分"问题"与"被检索的段落"：
    /// 检索用的模型通常要求两者加不同的前缀。
    func embed(_ texts: [String], kind: TextEmbeddingKind) async throws -> [[Float]]
}

public enum TextEmbeddingKind: Sendable, Equatable {
    case query
    case passage
}
