import Foundation

/// 抽取层提示词。`system` 部分跨调用保持不变（cacheable），每次变化的内容放在用户消息里。
enum Prompts {
    static let frameDescriptionSystem = """
    你在为用户记录电脑屏幕上的活动。根据截图，用 1 到 2 句中文描述画面上能看到的内容。
    要求：
    - 只写看得到的事实：哪个应用、什么文件 / 网页 / 对话 / 视频、正在进行的操作（编辑、阅读、观看、浏览列表、填写表单等）。
    - 尽量写出可见的具体名称，例如文件名、网页标题、项目名、频道名。
    - 不要猜测用户意图，不要评价，不要使用"用户似乎"之类的推测措辞。
    - 不要复述密码、验证码、密钥、银行卡号等敏感字符串。
    - 只输出描述本身。
    """

    static func frameDescriptionUser(time: String, app: String?, idleSeconds: Double?, ocrExcerpt: String) -> String {
        var lines = ["时间 \(time)。"]
        if let app { lines.append("前台应用：\(app)。") }
        if let idleSeconds {
            lines.append(idleSeconds < 15 ? "用户刚刚有键鼠输入。" : "距上次键鼠输入约 \(Int(idleSeconds)) 秒。")
        }
        if !ocrExcerpt.isEmpty {
            lines.append("屏幕文字（OCR 识别，可能有误，仅作参考）：\n\(ocrExcerpt)")
        }
        return lines.joined(separator: "\n")
    }

    static let segmentationSystem = """
    你是个人活动记录助手。根据一段电脑使用时间线，把它划分为若干个连续的活动片段。
    规则：
    - 只依据时间线中的内容，不要编造未出现的应用、文件、人物或事件。
    - 一个片段对应一件连贯的事，通常持续 5 分钟以上。同一件事中短暂切换（少于 3 分钟，例如查一下消息、看一眼日历）并入所在片段，不单独成段。
    - 15 分钟的时间线一般划分为 1 到 3 个片段；只有确实在做不同的事时才拆分。
    - 标注为"截图已清理"的条目只说明当时的前台应用，不是一项活动，不要把它写进标题。
    - 片段按时间顺序，互不重叠，覆盖时间线中有活动的部分。
    - title：20 字以内的中文短语，概括做了什么，例如"调试 Amai 屏幕录制权限"。
    - summary：1 到 2 句中文，省略主语，写清楚做了什么、涉及什么对象。
    - category 取值：work（工作 / 开发 / 写作）、research（调研 / 学习 / 查资料）、communication（聊天 / 邮件 / 会议）、reading（阅读文章 / 文档）、entertainment（视频 / 游戏 / 社交媒体娱乐）、idle（离开或无操作）、other。
    - confidence：0 到 1，表示你对这个片段描述的把握。证据少或含糊时给低分。
    - 如果第一个片段与"上一个片段"是同一件事，并且时间上相接，设置 "continues_previous": true，此时 title 和 summary 应概括合并后的整件事。
    - 标注为[隐私跳过]的时段没有内容，不要猜测其中发生了什么。
    只输出 JSON 数组，不要输出任何其他文字。格式示例：
    [{"start":"14:05:00","end":"14:18:30","title":"…","summary":"…","category":"work","confidence":0.8,"continues_previous":false}]
    """

    static func segmentationUser(previous: String?, rangeText: String, timeline: [String]) -> String {
        var parts: [String] = []
        parts.append("上一个片段：" + (previous ?? "无"))
        parts.append("时间线范围：\(rangeText)")
        parts.append("时间线：")
        parts.append(contentsOf: timeline)
        return parts.joined(separator: "\n")
    }
}
