import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit

/// 一帧截图及其来源显示器。`CGImage` 在当前 SDK 中未标注 Sendable，
/// 但它是不可变对象，跨 actor 传递安全。
public struct CapturedFrame: @unchecked Sendable {
    public let image: CGImage
    public let displayId: UInt32

    public init(image: CGImage, displayId: UInt32) {
        self.image = image
        self.displayId = displayId
    }
}

public enum ScreenCaptureError: Error, Equatable {
    case permissionDenied
    case noDisplay
    case captureFailed(String)
}

/// 屏幕采集的 I/O 边界。真实实现走 ScreenCaptureKit，测试用假源。
public protocol ScreenFrameSource: Sendable {
    func captureFrame(excludingBundleIds: Set<String>, targetHeight: Int) async throws -> CapturedFrame
}

/// Dayflow 风格：`SCScreenshotManager` 单帧截图，不开持续流，不触发系统录屏指示器。
/// 排除应用通过 `SCContentFilter(excludingApplications:)` 在系统层抠除。
public struct ScreenCaptureKitSource: ScreenFrameSource {
    public init() {}

    public func captureFrame(excludingBundleIds: Set<String>, targetHeight: Int) async throws -> CapturedFrame {
        guard CGPreflightScreenCaptureAccess() else {
            throw ScreenCaptureError.permissionDenied
        }

        let target = await Self.activeDisplay()

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw Self.map(error)
        }

        guard let display = content.displays.first(where: { $0.displayID == target?.id }) ?? content.displays.first
        else {
            throw ScreenCaptureError.noDisplay
        }

        // fail-closed：有窗口却枚举不到任何应用，说明共享内容不完整，
        // 排除过滤无法保证生效，宁可丢这一帧。
        if content.applications.isEmpty, !content.windows.isEmpty, !excludingBundleIds.isEmpty {
            throw ScreenCaptureError.captureFailed("shareable content incomplete")
        }
        let excludedApps = content.applications.filter { excludingBundleIds.contains($0.bundleIdentifier) }

        let filter = SCContentFilter(display: display, excludingApplications: excludedApps, exceptingWindows: [])

        let scale = target?.scale ?? 2
        let pixelWidth = CGFloat(display.width) * scale
        let pixelHeight = CGFloat(display.height) * scale
        let ratio = min(1, CGFloat(targetHeight) / pixelHeight)

        let config = SCStreamConfiguration()
        config.width = Self.even(pixelWidth * ratio)
        config.height = Self.even(pixelHeight * ratio)
        config.scalesToFit = true
        config.showsCursor = false
        config.capturesAudio = false

        do {
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            return CapturedFrame(image: image, displayId: display.displayID)
        } catch {
            throw Self.map(error)
        }
    }

    /// 鼠标所在显示器优先；取不到时用主显示器。
    @MainActor
    private static func activeDisplay() -> (id: UInt32, scale: CGFloat)? {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let screen,
              let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        else { return nil }
        return (number.uint32Value, screen.backingScaleFactor)
    }

    private static func even(_ value: CGFloat) -> Int {
        max(2, Int(value.rounded(.down)) & ~1)
    }

    private static func map(_ error: Error) -> ScreenCaptureError {
        let nsError = error as NSError
        if nsError.domain == SCStreamErrorDomain,
           nsError.code == SCStreamError.Code.userDeclined.rawValue {
            return .permissionDenied
        }
        return .captureFailed("\(nsError.domain)#\(nsError.code)")
    }
}
