import os

/// 日志约定（docs/architecture.md §2.5）：
/// - subsystem 固定，category 为模块名；
/// - **只记录计数、耗时、状态、错误**；OCR 文本、转录文本、窗口标题、
///   记忆内容等任何内容字段一律不得进入日志。
public enum AmaiLog {
    public static let subsystem = "com.amai.app"

    public static func logger(_ category: String) -> Logger {
        Logger(subsystem: subsystem, category: category)
    }
}
