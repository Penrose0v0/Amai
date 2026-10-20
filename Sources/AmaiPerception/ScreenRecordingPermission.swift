import AppKit
import CoreGraphics
import Foundation

/// 屏幕录制权限。`preflight` 可能返回陈旧结果（Screenpipe 经验），
/// 因此采集器以实际截图是否成功为准，这里只用于 UI 引导。
public enum ScreenRecordingPermission {
    public static func isGranted() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// 触发系统授权弹窗（仅首次有效）。返回当前是否已授权。
    @discardableResult
    public static func request() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    @MainActor
    public static func openSystemSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        NSWorkspace.shared.open(url)
    }
}
