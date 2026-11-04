import Foundation

/// 记忆语言：Amai 写入记忆的内容（活动片段标题与摘要、每日总结、各分区记忆）使用的语言。
/// 与界面语言分开设置。切换只影响之后新写入或修改的内容；已有内容不翻译。
/// 抽取与整理的提示词按此语言整份切换，代码生成的文字（统计行、变更记录等）也随之切换。
public enum MemoryLanguage: String, Codable, Sendable, CaseIterable {
    case zhHans = "zh-Hans"
    case en
    case ja

    public static let `default` = MemoryLanguage.zhHans

    /// 语言自身的名称，用于设置中的选项。
    public var nativeName: String {
        switch self {
        case .zhHans: "简体中文"
        case .en: "English"
        case .ja: "日本語"
        }
    }

    /// 无法识别的取值按默认语言处理，避免配置写错导致无法启动。
    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = MemoryLanguage(rawValue: raw) ?? .default
    }

    /// 按语言取值的小工具：`lang.pick("中文", "English", "日本語")`。
    public func pick<T>(_ zh: T, _ en: T, _ ja: T) -> T {
        switch self {
        case .zhHans: zh
        case .en: en
        case .ja: ja
        }
    }
}
