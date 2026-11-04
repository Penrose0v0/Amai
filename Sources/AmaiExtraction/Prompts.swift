import AmaiCore
import Foundation

/// 抽取层提示词，按记忆语言整份切换（中文为原始版本）。`system` 部分跨调用保持不变（cacheable），
/// 每次变化的内容放在用户消息里。JSON 字段名与 category 取值不随语言变化。
enum Prompts {
    // 测试与既有调用使用的默认（中文）版本。
    static let frameDescriptionSystem = frameDescriptionSystem(.zhHans)
    static let segmentationSystem = segmentationSystem(.zhHans)

    static func frameDescriptionSystem(_ lang: MemoryLanguage) -> String {
        lang.pick(
            """
            你在为用户记录电脑屏幕上的活动。根据截图，用 1 到 2 句中文描述画面上能看到的内容。
            要求：
            - 只写看得到的事实：哪个应用、什么文件 / 网页 / 对话 / 视频、正在进行的操作（编辑、阅读、观看、浏览列表、填写表单等）。
            - 尽量写出可见的具体名称，例如文件名、网页标题、项目名、频道名。
            - 不要猜测用户意图，不要评价，不要使用"用户似乎"之类的推测措辞。
            - 不要复述密码、验证码、密钥、银行卡号等敏感字符串。
            - 只输出描述本身。
            """,
            """
            You are recording what the user is doing on their computer screen. Based on the screenshot, describe what is visible in 1 to 2 English sentences.
            Requirements:
            - Only state visible facts: which app, which file / web page / conversation / video, and the action in progress (editing, reading, watching, browsing a list, filling in a form, etc.).
            - Include specific visible names where possible, such as file names, page titles, project names or channel names.
            - Do not guess the user's intent, do not judge, and avoid speculative wording such as "the user seems to".
            - Never repeat passwords, verification codes, keys, card numbers or other sensitive strings.
            - Output only the description.
            """,
            """
            あなたはユーザーのパソコン画面上の活動を記録しています。スクリーンショットをもとに、画面に見える内容を日本語 1〜2 文で説明してください。
            要件：
            - 見える事実だけを書く：どのアプリか、どのファイル / Web ページ / 会話 / 動画か、行っている操作（編集、閲覧、視聴、一覧の確認、フォーム入力など）。
            - ファイル名、ページタイトル、プロジェクト名、チャンネル名など、見える具体的な名前をできるだけ書く。
            - ユーザーの意図を推測したり評価したりしない。「ユーザーは〜のようだ」といった推測表現を使わない。
            - パスワード、認証コード、鍵、カード番号などの機密文字列を書き写さない。
            - 説明だけを出力する。
            """
        )
    }

    static func frameDescriptionUser(
        time: String, app: String?, idleSeconds: Double?, onFocusDisplay: Bool = true, ocrExcerpt: String,
        language lang: MemoryLanguage = .zhHans
    ) -> String {
        var lines = [lang.pick("时间 \(time)。", "Time: \(time).", "時刻 \(time)。")]
        if onFocusDisplay {
            if let app { lines.append(lang.pick("前台应用：\(app)。", "Frontmost app: \(app).", "最前面のアプリ：\(app)。")) }
            if let idleSeconds {
                lines.append(idleSeconds < 15
                    ? lang.pick("用户刚刚有键鼠输入。", "The user just used the keyboard or mouse.", "ユーザーは直前にキーボードかマウスを操作しました。")
                    : lang.pick("距上次键鼠输入约 \(Int(idleSeconds)) 秒。", "About \(Int(idleSeconds)) seconds since the last keyboard or mouse input.", "最後のキーボード・マウス入力から約 \(Int(idleSeconds)) 秒。"))
            }
        } else {
            // 前台应用在另一块屏幕上，给出它反而会误导描述。
            lines.append(lang.pick(
                "这是一块副屏（非焦点显示器）的截图，前台应用不在这块屏幕上，请只根据画面描述。",
                "This screenshot is from a secondary (non-focused) display. The frontmost app is not on this screen; describe only what is visible.",
                "これはサブ画面（フォーカスのないディスプレイ）のスクリーンショットです。最前面のアプリはこの画面にはありません。画面に見える内容だけを説明してください。"
            ))
        }
        if !ocrExcerpt.isEmpty {
            lines.append(lang.pick(
                "屏幕文字（OCR 识别，可能有误，仅作参考）：\n\(ocrExcerpt)",
                "On-screen text (OCR, may contain errors; for reference only):\n\(ocrExcerpt)",
                "画面上の文字（OCR 認識、誤りを含む可能性あり、参考のみ）：\n\(ocrExcerpt)"
            ))
        }
        return lines.joined(separator: "\n")
    }

    static func segmentationSystem(_ lang: MemoryLanguage) -> String {
        lang.pick(
            """
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
            - 时间线可能包含多块屏幕的画面，用[屏幕N·焦点]或[屏幕N·副屏]标注。所有屏幕合起来只输出一份活动记录，不要按屏幕分别划分片段。
            - 焦点屏是用户正在操作的屏幕，以它的内容为主要依据；副屏内容是背景，可以在 summary 中顺带提及（例如一边开着视频一边写代码）。焦点在某块屏幕上也不代表用户在全神贯注地看它。
            - 副屏画面持续变化（例如在播放视频）不代表用户在操作或在场，是否在操作以键鼠输入为准。
            只输出 JSON 数组，不要输出任何其他文字。格式示例：
            [{"start":"14:05:00","end":"14:18:30","title":"…","summary":"…","category":"work","confidence":0.8,"continues_previous":false}]
            """,
            """
            You are a personal activity logging assistant. Given a timeline of computer use, divide it into consecutive activity segments.
            Rules:
            - Use only what appears in the timeline. Do not invent apps, files, people or events that do not appear.
            - One segment is one coherent task, usually lasting 5 minutes or more. Brief switches within the same task (under 3 minutes, such as checking a message or glancing at a calendar) belong to that segment, not a separate one.
            - A 15-minute timeline is usually 1 to 3 segments; split only when the user was really doing different things.
            - Entries marked "screenshot expired" only tell you the frontmost app at that time. They are not an activity; do not put them in a title.
            - Segments are in time order, do not overlap, and cover the parts of the timeline with activity.
            - title: a short English phrase of at most 8 words summarizing what was done, e.g. "Debugging Amai screen recording permission".
            - summary: 1 to 2 English sentences without a subject, stating what was done and on what.
            - category values: work (work / development / writing), research (research / learning / looking things up), communication (chat / email / meetings), reading (reading articles / documents), entertainment (video / games / social media), idle (away or no activity), other.
            - confidence: 0 to 1, how sure you are of this segment's description. Give a low score when evidence is thin or ambiguous.
            - If the first segment is the same task as the "previous segment" and directly follows it in time, set "continues_previous": true; title and summary should then describe the merged task as a whole.
            - Periods marked [privacy skipped] have no content; do not guess what happened.
            - The timeline may contain several displays, labelled [Display N · focused] or [Display N · secondary]. Produce one record for all displays together; do not segment each display separately.
            - The focused display is the one the user is operating; base the record mainly on it. Secondary displays are background and may be mentioned in the summary (e.g. writing code with a video open). Focus on a display does not mean the user is fully concentrating on it.
            - Continuous change on a secondary display (e.g. a playing video) does not mean the user is operating or present; keyboard and mouse input decides that.
            Output only a JSON array, with no other text. Example:
            [{"start":"14:05:00","end":"14:18:30","title":"…","summary":"…","category":"work","confidence":0.8,"continues_previous":false}]
            """,
            """
            あなたは個人の活動記録アシスタントです。パソコン利用のタイムラインを、連続した活動区間に分けてください。
            ルール：
            - タイムラインの内容だけに基づき、出てこないアプリ、ファイル、人物、出来事を作らない。
            - 1 つの区間は 1 つのまとまった作業で、通常 5 分以上続く。同じ作業中の短い切り替え（3 分未満。メッセージの確認やカレンダーをちらっと見るなど）はその区間に含め、別区間にしない。
            - 15 分のタイムラインは通常 1〜3 区間。本当に別のことをしているときだけ分ける。
            - 「スクリーンショット削除済み」と付いた項目は、そのときの最前面アプリを示すだけで活動ではない。タイトルに入れない。
            - 区間は時間順で、重ならず、タイムラインの活動部分を覆う。
            - title：何をしたかをまとめた 20 文字以内の日本語の句。例：「Amai の画面収録権限をデバッグ」。
            - summary：主語を省いた日本語 1〜2 文。何を、何に対して行ったかを書く。
            - category の値：work（仕事 / 開発 / 執筆）、research（調査 / 学習 / 調べもの）、communication（チャット / メール / 会議）、reading（記事 / 文書を読む）、entertainment（動画 / ゲーム / SNS）、idle（離席または操作なし）、other。
            - confidence：0〜1。この区間の説明にどれだけ自信があるか。根拠が少ない、曖昧なときは低くする。
            - 最初の区間が「直前の区間」と同じ作業で時間的に続いている場合は "continues_previous": true とし、title と summary は統合した作業全体をまとめる。
            - [プライバシーによりスキップ] と付いた時間帯には内容がない。何があったか推測しない。
            - タイムラインには複数の画面が含まれることがあり、[画面N・フォーカス] または [画面N・サブ] と表示される。すべての画面を合わせて 1 つの記録だけを出力し、画面ごとに区間を分けない。
            - フォーカス画面はユーザーが操作している画面で、主な根拠とする。サブ画面は背景で、summary で触れてもよい（例：動画を流しながらコードを書く）。フォーカスがあるからといって、その画面に集中しているとは限らない。
            - サブ画面が変化し続けていても（動画再生など）、ユーザーが操作している・在席しているとは限らない。操作の有無はキーボードとマウスの入力で判断する。
            JSON 配列だけを出力し、ほかの文字は出力しない。例：
            [{"start":"14:05:00","end":"14:18:30","title":"…","summary":"…","category":"work","confidence":0.8,"continues_previous":false}]
            """
        )
    }

    static func segmentationUser(previous: String?, rangeText: String, timeline: [String], language lang: MemoryLanguage = .zhHans) -> String {
        var parts: [String] = []
        parts.append(lang.pick("上一个片段：", "Previous segment: ", "直前の区間：") + (previous ?? lang.pick("无", "none", "なし")))
        parts.append(lang.pick("时间线范围：", "Timeline range: ", "タイムラインの範囲：") + rangeText)
        parts.append(lang.pick("时间线：", "Timeline:", "タイムライン："))
        parts.append(contentsOf: timeline)
        return parts.joined(separator: "\n")
    }
}

/// 抽取层生成的、会进入记忆或提示词的文字（时间线标注、规则片段与兜底片段的标题和摘要）。
struct ExtractionText {
    let lang: MemoryLanguage

    var unknownApp: String { lang.pick("未知应用", "Unknown app", "不明なアプリ") }

    func switchedTo(_ app: String) -> String { lang.pick("切换到 \(app)", "switched to \(app)", "\(app) に切り替え") }
    var privacySkipped: String { lang.pick("[隐私跳过]", "[privacy skipped]", "[プライバシーによりスキップ]") }
    func displayName(_ n: Int) -> String { lang.pick("屏幕\(n)", "Display \(n)", "画面\(n)") }
    func displayTag(_ name: String, focused: Bool) -> String {
        lang.pick("[\(name)·\(focused ? "焦点" : "副屏")]", "[\(name) · \(focused ? "focused" : "secondary")]", "[\(name)・\(focused ? "フォーカス" : "サブ")]")
    }
    var overviewTag: String { lang.pick("[屏幕概况]", "[display overview]", "[画面の概況]") }
    func overview(_ name: String, focusPercent: Int, changed: Int?, of total: Int) -> String {
        var text = lang.pick("\(name)：焦点约 \(focusPercent)% 的时间", "\(name): focused about \(focusPercent)% of the time", "\(name)：約 \(focusPercent)% の時間フォーカス")
        if let changed {
            text += lang.pick("，画面变化 \(changed)/\(total) 次截图", ", screen changed in \(changed)/\(total) screenshots", "、画面変化 \(changed)/\(total) 回")
        }
        return text
    }
    var overviewSeparator: String { lang.pick("；", "; ", "；") }
    func screen(_ description: String) -> String { lang.pick(" 画面：\(description)", " screen: \(description)", " 画面：\(description)") }
    func expiredWithText(_ hint: String) -> String {
        lang.pick("（截图已清理）文字线索：\(hint)", " (screenshot expired) text clues: \(hint)", "（スクリーンショット削除済み）文字の手がかり：\(hint)")
    }
    var expiredFocused: String { lang.pick("（截图已清理，仅知前台应用）", " (screenshot expired; only the frontmost app is known)", "（スクリーンショット削除済み、最前面のアプリのみ判明）") }
    var expired: String { lang.pick("（截图已清理）", " (screenshot expired)", "（スクリーンショット削除済み）") }
    func idleFor(_ seconds: Int) -> String {
        lang.pick("（已 \(seconds) 秒无键鼠输入）", " (no keyboard or mouse input for \(seconds) s)", "（\(seconds) 秒間キーボード・マウス入力なし）")
    }

    // 规则片段与兜底片段
    var awayTitle: String { lang.pick("离开电脑", "Away from computer", "離席") }
    var awaySummary: String {
        lang.pick("键鼠长时间无输入且焦点屏画面基本不变。", "No keyboard or mouse input for a long time and the focused screen barely changed.", "長時間キーボード・マウスの入力がなく、フォーカス画面もほぼ変化なし。")
    }
    var otherScreensChanging: String {
        lang.pick("其他屏幕的画面仍在变化（可能在自动播放）。", " Other displays kept changing (possibly autoplay).", "ほかの画面は変化し続けていた（自動再生の可能性）。")
    }
    var privacySummary: String { lang.pick("此时段按隐私设置未采集画面。", "Screen not captured during this period due to privacy settings.", "プライバシー設定により、この時間帯は画面を記録していません。") }
    func skipTitle(_ reason: String) -> String {
        switch reason {
        case "userPaused": lang.pick("采集已暂停", "Recording paused", "記録を一時停止")
        case "secureInput": lang.pick("隐私跳过：密码输入", "Privacy skip: password entry", "プライバシーによりスキップ：パスワード入力")
        case "excludedApp": lang.pick("隐私跳过：排除的应用", "Privacy skip: excluded app", "プライバシーによりスキップ：除外したアプリ")
        default: lang.pick("隐私跳过", "Privacy skip", "プライバシーによりスキップ")
        }
    }
    func fallbackTitle(_ app: String) -> String { lang.pick("使用 \(app)", "Using \(app)", "\(app) を使用") }
    var fallbackSummary: String {
        lang.pick("模型处理失败，仅根据前台应用记录。", "Model processing failed; recorded from the frontmost app only.", "モデルの処理に失敗したため、最前面のアプリのみから記録。")
    }
}
