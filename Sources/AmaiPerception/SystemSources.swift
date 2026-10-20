import AppKit
import Carbon
import CoreGraphics
import Foundation

// 采集器依赖的系统信息源。每个都是小协议 + 系统实现，便于在测试中替换。

// MARK: - 空闲时长

public protocol IdleTimeSource: Sendable {
    /// 距上次任意用户输入的秒数。
    func secondsSinceLastInput() -> TimeInterval
}

/// 不需要任何权限。对多种事件类型取最小值，等价于"任意输入"。
public struct SystemIdleTimeSource: IdleTimeSource {
    public init() {}

    public func secondsSinceLastInput() -> TimeInterval {
        let types: [CGEventType] = [
            .keyDown, .flagsChanged, .mouseMoved, .leftMouseDown, .rightMouseDown,
            .otherMouseDown, .scrollWheel, .leftMouseDragged, .rightMouseDragged,
        ]
        return types
            .map { CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: $0) }
            .min() ?? 0
    }
}

// MARK: - 安全输入

public protocol SecureInputDetector: Sendable {
    /// 系统安全输入模式（密码框获得焦点）是否激活。
    func isSecureInputActive() -> Bool
}

public struct SystemSecureInputDetector: SecureInputDetector {
    public init() {}

    public func isSecureInputActive() -> Bool {
        IsSecureEventInputEnabled()
    }
}

// MARK: - 前台应用

public struct FrontmostApp: Sendable, Equatable {
    public let name: String?
    public let bundleId: String?
    public let pid: Int32

    public init(name: String?, bundleId: String?, pid: Int32) {
        self.name = name
        self.bundleId = bundleId
        self.pid = pid
    }
}

public protocol FrontmostAppSource: Sendable {
    func frontmostApp() async -> FrontmostApp?
}

public struct SystemFrontmostAppSource: FrontmostAppSource {
    public init() {}

    public func frontmostApp() async -> FrontmostApp? {
        await MainActor.run {
            guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
            return FrontmostApp(
                name: app.localizedName,
                bundleId: app.bundleIdentifier,
                pid: app.processIdentifier
            )
        }
    }
}
