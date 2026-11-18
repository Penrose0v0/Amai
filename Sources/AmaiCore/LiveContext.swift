import Foundation

// 交互式（用户正在使用 Agent 或快速操作时）读取屏幕的数据契约。
// 由感知层实现：与后台采集共用同一套截图、OCR、辅助功能读取和隐私策略，只是读取时机不同——
// 后台按固定间隔采集并写入原始缓冲，交互式读取只在用户发起时进行，结果只留在内存里。

public enum ScreenScope: String, Sendable, Codable {
    /// 用户正在操作的那块显示器的完整画面。
    case desktop
    /// 前台应用的主窗口。
    case focusedWindow
}

/// 一张即时截图（JPEG）。
public struct ScreenImage: Sendable, Equatable {
    public let jpeg: Data
    /// dHash，用于判断屏幕是否变化。
    public let perceptualHash: UInt64
    public let scope: ScreenScope
    public let capturedAt: Date
    /// 是否复用了后台采集刚截到的帧（而不是为这次读取新截的）。
    public let reusedBackgroundFrame: Bool

    public init(jpeg: Data, perceptualHash: UInt64, scope: ScreenScope, capturedAt: Date, reusedBackgroundFrame: Bool) {
        self.jpeg = jpeg
        self.perceptualHash = perceptualHash
        self.scope = scope
        self.capturedAt = capturedAt
        self.reusedBackgroundFrame = reusedBackgroundFrame
    }
}

/// 用户当前的焦点：前台应用、窗口标题与选中的文字。窗口标题和选区需要辅助功能权限，没有权限时为 nil。
public struct FocusSnapshot: Sendable, Equatable {
    public var appName: String?
    public var bundleId: String?
    public var pid: Int32?
    public var windowTitle: String?
    public var selectedText: String?
    /// 选区所在的控件是否可编辑（决定能否"替换选中文字"）。
    public var selectionIsEditable: Bool
    /// 是否有辅助功能权限。
    public var accessibilityGranted: Bool
    public var capturedAt: Date

    public init(
        appName: String? = nil, bundleId: String? = nil, pid: Int32? = nil, windowTitle: String? = nil,
        selectedText: String? = nil, selectionIsEditable: Bool = false, accessibilityGranted: Bool = false,
        capturedAt: Date = Date()
    ) {
        self.appName = appName
        self.bundleId = bundleId
        self.pid = pid
        self.windowTitle = windowTitle
        self.selectedText = selectedText
        self.selectionIsEditable = selectionIsEditable
        self.accessibilityGranted = accessibilityGranted
        self.capturedAt = capturedAt
    }
}

/// 最近一段时间里屏幕上出现过的一个"文本状态"：某个应用某一屏的文字。
public struct RecentTextState: Sendable, Equatable {
    public enum Source: String, Sendable, Codable {
        case ocr
        case accessibility
    }

    public let firstSeen: Date
    public let lastSeen: Date
    public let appName: String?
    public let windowTitle: String?
    public let text: String
    public let source: Source

    public init(firstSeen: Date, lastSeen: Date, appName: String?, windowTitle: String?, text: String, source: Source) {
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
        self.appName = appName
        self.windowTitle = windowTitle
        self.text = text
        self.source = source
    }
}

public enum LiveContextError: Error, Equatable, Sendable {
    /// 隐私策略不允许读取（被排除的应用在前台、正在输入密码等）。`reason` 是策略给出的原因代码。
    case blocked(reason: String)
    case screenRecordingDenied
    case unavailable(String)
}

/// Agent 与快速操作读取实时上下文的接口。
public protocol LiveContextReading: Sendable {
    /// 当前焦点：应用、窗口、选区。被隐私策略拦下时只返回空快照（不含应用名）。
    func focus() async -> FocusSnapshot

    /// 即时截图。后台采集在 `maxAge` 秒内截到过同一前台应用的画面时直接复用，否则现截。
    func screen(_ scope: ScreenScope, maxAge: TimeInterval, maxHeight: Int) async throws -> ScreenImage

    /// 当前屏幕上的文字（对 `screen` 的结果做 OCR）。
    func screenText(_ scope: ScreenScope, maxAge: TimeInterval) async throws -> String

    /// 最近几分钟的文本状态，从旧到新。OCR 在这里按需进行并缓存。
    func recentStates() async -> [RecentTextState]
}
