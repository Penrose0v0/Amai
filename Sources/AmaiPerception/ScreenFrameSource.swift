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

/// 一次 tick 截到的所有显示器画面。
public struct ScreenCapture: Sendable {
    public let frames: [CapturedFrame]
    /// 焦点屏：前台应用主窗口所在的显示器，取不到时为鼠标所在显示器。
    /// 只说明用户在哪块屏幕上操作，不代表用户在专注看它。
    public let focusDisplayId: UInt32?

    public init(frames: [CapturedFrame], focusDisplayId: UInt32?) {
        self.frames = frames
        self.focusDisplayId = focusDisplayId
    }
}

public enum ScreenCaptureError: Error, Equatable {
    case permissionDenied
    case noDisplay
    case captureFailed(String)
}

/// 屏幕采集的 I/O 边界。真实实现走 ScreenCaptureKit，测试用假源。
public protocol ScreenFrameSource: Sendable {
    /// 截取当前连接的所有显示器。`frontmostPid` 用于判定焦点屏。
    /// 部分显示器失败时返回其余显示器的画面；全部失败才抛错。
    func captureAll(excludingBundleIds: Set<String>, targetHeight: Int, frontmostPid: pid_t?) async throws -> ScreenCapture
}

/// Dayflow 风格：`SCScreenshotManager` 单帧截图，不开持续流，不触发系统录屏指示器。
/// 排除应用通过 `SCContentFilter(excludingApplications:)` 在系统层抠除。
/// 多显示器时每块屏幕单独截一张，各自写入独立的视频分段。
public struct ScreenCaptureKitSource: ScreenFrameSource {
    public init() {}

    public func captureAll(excludingBundleIds: Set<String>, targetHeight: Int, frontmostPid: pid_t?) async throws -> ScreenCapture {
        guard CGPreflightScreenCaptureAccess() else {
            throw ScreenCaptureError.permissionDenied
        }

        let screens = await Self.screenInfo()

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw Self.map(error)
        }
        guard !content.displays.isEmpty else { throw ScreenCaptureError.noDisplay }

        // fail-closed：有窗口却枚举不到任何应用，说明共享内容不完整，
        // 排除过滤无法保证生效，宁可丢这一帧。
        if content.applications.isEmpty, !content.windows.isEmpty, !excludingBundleIds.isEmpty {
            throw ScreenCaptureError.captureFailed("shareable content incomplete")
        }
        let excludedApps = content.applications.filter { excludingBundleIds.contains($0.bundleIdentifier) }

        // 逐块截取：显示器数量很少，单张截图只需几十毫秒，串行也避免同时持有多张全尺寸图像。
        var results: [Result<CapturedFrame, ScreenCaptureError>] = []
        for display in content.displays.sorted(by: { $0.displayID < $1.displayID }) {
            let scale = screens.scales[display.displayID] ?? 2
            results.append(await Self.capture(display, scale: scale, excluding: excludedApps, targetHeight: targetHeight))
        }
        let frames = results.compactMap { try? $0.get() }
        guard !frames.isEmpty else {
            let errors = results.compactMap { if case .failure(let e) = $0 { e } else { nil } }
            throw errors.first(where: { $0 == .permissionDenied }) ?? errors.first ?? .noDisplay
        }

        let focus = Self.focusDisplay(content: content, frontmostPid: frontmostPid) ?? screens.mouseDisplay
        return ScreenCapture(frames: frames, focusDisplayId: focus)
    }

    private static func capture(
        _ display: SCDisplay, scale: CGFloat, excluding excludedApps: [SCRunningApplication], targetHeight: Int
    ) async -> Result<CapturedFrame, ScreenCaptureError> {
        let filter = SCContentFilter(display: display, excludingApplications: excludedApps, exceptingWindows: [])
        let pixelWidth = CGFloat(display.width) * scale
        let pixelHeight = CGFloat(display.height) * scale
        let ratio = min(1, CGFloat(targetHeight) / pixelHeight)

        let config = SCStreamConfiguration()
        config.width = even(pixelWidth * ratio)
        config.height = even(pixelHeight * ratio)
        config.scalesToFit = true
        config.showsCursor = false
        config.capturesAudio = false

        do {
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            return .success(CapturedFrame(image: image, displayId: display.displayID))
        } catch {
            return .failure(map(error))
        }
    }

    /// 前台应用在屏幕上面积最大的普通窗口（layer 0）与哪块显示器重叠最多，就是焦点屏。
    /// 只用窗口几何，不读取窗口标题。
    private static func focusDisplay(content: SCShareableContent, frontmostPid: pid_t?) -> UInt32? {
        guard let frontmostPid else { return nil }
        let windows = content.windows.filter {
            $0.owningApplication?.processID == frontmostPid && $0.windowLayer == 0 && $0.isOnScreen
        }
        guard let window = windows.max(by: { area($0.frame) < area($1.frame) }) else { return nil }
        let best = content.displays.max { area($0.frame.intersection(window.frame)) < area($1.frame.intersection(window.frame)) }
        guard let best, area(best.frame.intersection(window.frame)) > 0 else { return nil }
        return best.displayID
    }

    private static func area(_ rect: CGRect) -> CGFloat {
        rect.isNull ? 0 : rect.width * rect.height
    }

    /// 各显示器的缩放比例，以及鼠标所在显示器（焦点屏的兜底）。
    @MainActor
    private static func screenInfo() -> (scales: [UInt32: CGFloat], mouseDisplay: UInt32?) {
        var scales: [UInt32: CGFloat] = [:]
        var mouseDisplay: UInt32?
        let mouse = NSEvent.mouseLocation
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { continue }
            scales[number.uint32Value] = screen.backingScaleFactor
            if NSMouseInRect(mouse, screen.frame, false) { mouseDisplay = number.uint32Value }
        }
        return (scales, mouseDisplay)
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
