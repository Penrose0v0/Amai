import AmaiCore
import AppKit
import CoreGraphics
import Foundation
import os
import ScreenCaptureKit

/// 采集器每次成功截图（或因隐私 / 系统状态没有截图）后通知的对象。
public protocol ScreenCaptureObserver: Sendable {
    func didCapture(_ capture: ScreenCapture, hashes: [UInt32: UInt64], frontmost: FrontmostApp?, at time: Date) async
    /// 这一次没有截图（被排除的应用在前台、安全输入、暂停、睡眠等）。之前留在内存里的画面不应再被复用。
    func didNotCapture() async
}

/// 截取单个窗口的 I/O 边界。真实实现走 ScreenCaptureKit，测试用假源。
public protocol WindowFrameSource: Sendable {
    /// 截取 `pid` 在屏幕上面积最大的普通窗口；没有合适的窗口时返回 nil。
    func captureFrontWindow(pid: pid_t, maxHeight: Int) async throws -> CapturedFrame?
}

extension ScreenCaptureKitSource: WindowFrameSource {
    public func captureFrontWindow(pid: pid_t, maxHeight: Int) async throws -> CapturedFrame? {
        guard CGPreflightScreenCaptureAccess() else { throw ScreenCaptureError.permissionDenied }
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        } catch {
            throw ScreenCaptureError.captureFailed("shareable content")
        }
        let windows = content.windows.filter {
            $0.owningApplication?.processID == pid && $0.windowLayer == 0 && $0.isOnScreen
                && $0.frame.width > 80 && $0.frame.height > 80
        }
        guard let window = windows.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) else {
            return nil
        }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let scale = CGFloat(filter.pointPixelScale)
        let pixelHeight = window.frame.height * scale
        let ratio = min(1, CGFloat(maxHeight) / max(1, pixelHeight))
        let config = SCStreamConfiguration()
        config.width = max(2, Int(window.frame.width * scale * ratio) & ~1)
        config.height = max(2, Int(pixelHeight * ratio) & ~1)
        config.scalesToFit = true
        config.showsCursor = false
        config.capturesAudio = false
        do {
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            return CapturedFrame(image: image, displayId: 0)
        } catch {
            throw ScreenCaptureError.captureFailed("window capture")
        }
    }
}

/// 记住"用户正在用的那个应用"：最近一次被激活的、不是 Amai 自己的应用。
/// Amai 的窗口成为前台时，`NSWorkspace.frontmostApplication` 是 Amai 自己，而用户想问的是之前那个应用。
/// （移植自 Eira 的 FrontmostAppTracker。）
public final class TargetAppTracker: FrontmostAppSource, @unchecked Sendable {
    private let current = OSAllocatedUnfairLock<FrontmostApp?>(initialState: nil)
    // 只在主线程上读写。
    @MainActor private var observer: (any NSObjectProtocol)?
    private let ownPid = ProcessInfo.processInfo.processIdentifier

    public init() {}

    @MainActor
    public func start(onActivate: (@Sendable (FrontmostApp) -> Void)? = nil) {
        guard observer == nil else { return }
        if let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != ownPid {
            current.withLock { $0 = FrontmostApp(name: app.localizedName, bundleId: app.bundleIdentifier, pid: app.processIdentifier) }
        }
        let ownPid = self.ownPid
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.processIdentifier != ownPid
            else { return }
            let target = FrontmostApp(name: app.localizedName, bundleId: app.bundleIdentifier, pid: app.processIdentifier)
            self?.current.withLock { $0 = target }
            onActivate?(target)
        }
    }

    @MainActor
    public func stop() {
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observer = nil
    }

    public func frontmostApp() async -> FrontmostApp? {
        current.withLock { $0 }
    }
}

/// 交互式屏幕读取（`LiveContextReading` 的实现）。
///
/// 与后台采集共用同一个截图源、OCR、辅助功能读取与隐私策略：
/// - 采集器每次截图后把画面交到这里，留在内存里（每块显示器一帧）。交互式读取在画面还新鲜、
///   前台应用没变时直接复用，否则现截一张。这也绕开了"视频分段写入期间读不到最新截图"的限制；
/// - 同一批画面喂给 `RecentContextBuffer`，形成最近几分钟的文本状态；
/// - 被排除的应用在前台或正在输入密码时，交互式读取同样被拒绝。用户暂停后台采集只停止后台的部分：
///   交互式读取是用户当下主动发起的，仍然可用，但"最近状态"不再积累并被清空。
public actor LiveContextReader: LiveContextReading, ScreenCaptureObserver {
    public struct Dependencies: Sendable {
        public var screens: any ScreenFrameSource
        public var windows: any WindowFrameSource
        public var target: any FrontmostAppSource
        public var secureInput: any SecureInputDetector
        public var policy: any PrivacyPolicy
        public var ocr: any TextRecognizer
        public var focus: any FocusReading
        /// 辅助功能读不到选区时的菜单复制回退。只用于聊天快捷键打开面板之前（`focusForChatOpening`）；nil 时不复制。
        public var copier: (any SelectionCopying)?
        public var clock: any AmaiClock
        /// 截图时额外从画面中抠掉的应用（Amai 自己，避免把聊天面板截进去）。
        public var alwaysExcludedBundleIds: Set<String>

        public init(
            screens: any ScreenFrameSource,
            windows: any WindowFrameSource,
            target: any FrontmostAppSource,
            secureInput: any SecureInputDetector,
            policy: any PrivacyPolicy,
            ocr: any TextRecognizer,
            focus: any FocusReading,
            copier: (any SelectionCopying)? = nil,
            clock: any AmaiClock = SystemClock(),
            alwaysExcludedBundleIds: Set<String> = []
        ) {
            self.screens = screens
            self.windows = windows
            self.target = target
            self.secureInput = secureInput
            self.policy = policy
            self.ocr = ocr
            self.focus = focus
            self.copier = copier
            self.clock = clock
            self.alwaysExcludedBundleIds = alwaysExcludedBundleIds
        }
    }

    private struct LatestFrame {
        let frame: CapturedFrame
        let hash: UInt64
        let capturedAt: Date
        let bundleId: String?
    }

    /// 一个状态的文字上限：足够看出"当时屏幕上是什么"，又不至于把上下文撑大。
    static let recentTextLimit = 1200
    /// 一次焦点读取（窗口标题 + 选区）的总时限，超过就当作没有读到。
    static let focusReadLimit: Duration = .milliseconds(1200)
    /// 当前屏幕文字的上限。
    static let screenTextLimit = 6000
    /// 应用切换后等画面稳定再记录的时间。
    static let appSwitchSettle: Duration = .milliseconds(1500)

    /// 复用上一次 OCR 结果的条件：画面哈希相差不超过这么多位，且不超过这么久。
    /// 时间限制是因为哈希看不出小改动（在编辑器里多打了几个字）。
    static let recognitionReuseDistance = 3
    static let recognitionReuseWindow: TimeInterval = 90

    private var deps: Dependencies
    private var targetHeight: Int
    private var lastRecognition: (scope: ScreenScope, hash: UInt64, text: String, at: Date)?
    private var latest: LatestFrame?
    private var recent = RecentContextBuffer()
    private var backgroundActive = false
    private var switchTask: Task<Void, Never>?
    private let log = AmaiLog.logger("perception.live")

    public init(dependencies: Dependencies, targetHeight: Int = 1080) {
        self.deps = dependencies
        self.targetHeight = targetHeight
    }

    // MARK: - 与后台采集的衔接

    public func updatePolicy(_ policy: any PrivacyPolicy) {
        deps.policy = policy
        forget()
    }

    public func updateTargetHeight(_ height: Int) {
        targetHeight = height
    }

    /// 后台采集是否在运行（未停止、未被用户暂停）。只有运行时才积累最近状态。
    public func setBackgroundActive(_ active: Bool) {
        backgroundActive = active
        if !active { forget() }
    }

    /// 丢掉内存中的画面与最近状态（暂停、删除数据、策略变化时）。
    public func forget() {
        latest = nil
        lastRecognition = nil
        recent.clear()
        switchTask?.cancel()
    }

    public func didCapture(_ capture: ScreenCapture, hashes: [UInt32: UInt64], frontmost: FrontmostApp?, at time: Date) {
        guard let frame = Self.focusFrame(capture) else { return }
        let hash = hashes[frame.displayId] ?? ImageHashing.dHash(frame.image)
        latest = LatestFrame(frame: frame, hash: hash, capturedAt: time, bundleId: frontmost?.bundleId)
        guard backgroundActive else { return }
        noteRecent(frame: frame, hash: hash, app: frontmost, at: time)
    }

    public func didNotCapture() {
        latest = nil
    }

    /// 应用切换：等画面稳定后记一次状态，不必等到下一个采集周期（短暂停留的应用也能留下记录）。
    public func appDidActivate(_ app: FrontmostApp) {
        AccessibilityReader.prepare(pid: app.pid, bundleId: app.bundleId)
        guard backgroundActive else { return }
        switchTask?.cancel()
        switchTask = Task { [weak self] in
            try? await Task.sleep(for: Self.appSwitchSettle)
            guard !Task.isCancelled else { return }
            await self?.recordAfterSwitch(app)
        }
    }

    private func recordAfterSwitch(_ app: FrontmostApp) async {
        guard backgroundActive, (try? checkPolicy(app)) != nil else { return }
        guard let capture = try? await captureDisplays(frontmostPid: app.pid),
              let frame = Self.focusFrame(capture), backgroundActive
        else { return }
        let now = deps.clock.now()
        let hash = ImageHashing.dHash(frame.image)
        latest = LatestFrame(frame: frame, hash: hash, capturedAt: now, bundleId: app.bundleId)
        noteRecent(frame: frame, hash: hash, app: app, at: now)
    }

    private func noteRecent(frame: CapturedFrame, hash: UInt64, app: FrontmostApp?, at time: Date) {
        // 窗口标题是一次进程间查询，只在画面确实变了、要更新状态时才读。
        let unchanged = recent.isSameAsLast(hash: hash, bundleId: app?.bundleId)
        let title = unchanged ? nil : app.flatMap { deps.focus.isTrusted ? deps.focus.windowTitle(pid: $0.pid) : nil }
        recent.note(hash: hash, appName: app?.name, bundleId: app?.bundleId, windowTitle: title, at: time) {
            try? JPEGEncoder.encode(Self.scale(frame.image, maxHeight: 1080), quality: 0.7)
        }
    }

    // MARK: - LiveContextReading

    /// 只经辅助功能读取焦点与选区，不发送任何按键、不碰剪贴板。聊天面板的定期刷新用它。
    public func focus() async -> FocusSnapshot {
        await readFocus(copyFallback: false)
    }

    /// 聊天快捷键打开面板之前调用一次：辅助功能读不到选区时，只在菜单栏"拷贝"可用（有选区的证据）
    /// 时经菜单复制一次，随后恢复剪贴板；不发送按键，不用于任何定期或自动的读取。
    public func focusForChatOpening() async -> FocusSnapshot {
        await readFocus(copyFallback: true)
    }

    private func readFocus(copyFallback: Bool) async -> FocusSnapshot {
        let now = deps.clock.now()
        let trusted = deps.focus.isTrusted
        guard let app = await deps.target.frontmostApp(), (try? checkPolicy(app)) != nil else {
            return FocusSnapshot(accessibilityGranted: trusted, capturedAt: now)
        }
        var snapshot = FocusSnapshot(
            appName: app.name, bundleId: app.bundleId, pid: app.pid, accessibilityGranted: trusted, capturedAt: now
        )
        guard trusted else { return snapshot }
        // AX 查询是同步的进程间调用，放到专用队列并限定总时长，不占用 actor。
        let reader = deps.focus
        let (title, read) = await BlockingCall.value(
            within: Self.focusReadLimit, fallback: (String?.none, SelectionRead.none(.unresponsive))
        ) {
            (reader.windowTitle(pid: app.pid), reader.readSelection(pid: app.pid, bundleId: app.bundleId))
        }
        var selection = read.selection
        if copyFallback { log.info("chat opening read: \(Self.describe(read), privacy: .public)") }
        if copyFallback, let copier = deps.copier, !deps.secureInput.isSecureInputActive(),
           CopyFallback.applies(read: read, amaiHasKeyboard: false, secureInput: false),
           let text = await copier.copySelection(from: app.pid) {
            selection = TextSelection(text: text, pid: app.pid, source: .copy)
        }
        snapshot.windowTitle = title
        snapshot.selectedText = selection?.text
        snapshot.selectionIsCopied = selection?.source == .copy
        return snapshot
    }

    public func screen(_ scope: ScreenScope, maxAge: TimeInterval = 2, maxHeight: Int = 1080) async throws -> ScreenImage {
        let app = await deps.target.frontmostApp()
        try checkPolicy(app)
        let now = deps.clock.now()

        if scope == .focusedWindow, let app {
            do {
                if let frame = try await deps.windows.captureFrontWindow(pid: app.pid, maxHeight: maxHeight) {
                    return try Self.encode(frame.image, scope: .focusedWindow, at: now, maxHeight: maxHeight, reused: false)
                }
            } catch ScreenCaptureError.permissionDenied {
                throw LiveContextError.screenRecordingDenied
            } catch {
                log.info("window capture failed, falling back to the display")
            }
        }

        if let latest, now.timeIntervalSince(latest.capturedAt) <= maxAge, latest.bundleId == app?.bundleId {
            return try Self.encode(latest.frame.image, scope: .desktop, at: latest.capturedAt, maxHeight: maxHeight, reused: true)
        }
        let capture: ScreenCapture
        do {
            capture = try await captureDisplays(frontmostPid: app?.pid)
        } catch ScreenCaptureError.permissionDenied {
            throw LiveContextError.screenRecordingDenied
        } catch {
            throw LiveContextError.unavailable("capture failed")
        }
        guard let frame = Self.focusFrame(capture) else { throw LiveContextError.unavailable("no display") }
        latest = LatestFrame(frame: frame, hash: ImageHashing.dHash(frame.image), capturedAt: now, bundleId: app?.bundleId)
        return try Self.encode(frame.image, scope: .desktop, at: now, maxHeight: maxHeight, reused: false)
    }

    /// 画面与上一次识别时基本相同（且隔得不久）就直接返回上次的文字，不重复 OCR。
    /// 助手在面板唤出时识别一次，用户提交问题时再读一次做确认：屏幕没变的话第二次只花一次截图的时间。
    public func screenText(_ scope: ScreenScope, maxAge: TimeInterval = 2) async throws -> String {
        let image = try await screen(scope, maxAge: maxAge, maxHeight: 1440)
        let now = deps.clock.now()
        if let last = lastRecognition, last.scope == image.scope,
           now.timeIntervalSince(last.at) <= Self.recognitionReuseWindow,
           (last.hash ^ image.perceptualHash).nonzeroBitCount <= Self.recognitionReuseDistance {
            return last.text
        }
        let text = await recognize(image.jpeg, limit: Self.screenTextLimit)
        lastRecognition = (image.scope, image.perceptualHash, text, now)
        return text
    }

    public func recentStates() async -> [RecentTextState] {
        recent.prune(now: deps.clock.now())
        for index in recent.states.indices where recent.states[index].text == nil {
            let jpeg = recent.states[index].jpeg
            let hash = recent.states[index].hash
            let text = await recognize(jpeg, limit: Self.recentTextLimit)
            // OCR 期间状态可能被更新或淘汰：按画面哈希找回原来的那个状态再写入。
            if let current = recent.states.firstIndex(where: { $0.hash == hash && $0.text == nil }) {
                recent.setText(text, at: current)
            }
        }
        return recent.distinctStates()
    }

    // MARK: - Private

    /// 读取结果的类别（不含文字）。
    private static func describe(_ read: SelectionRead) -> String {
        switch read {
        case .text: "text"
        case .unknown: "unknown"
        case .emptyField: "emptyField"
        case .none(let miss): "none(\(miss))"
        }
    }

    private func checkPolicy(_ app: FrontmostApp?) throws {
        let context = CaptureContext(
            frontmostBundleId: app?.bundleId, frontmostAppName: app?.name,
            secureInputActive: deps.secureInput.isSecureInputActive(), userPaused: false
        )
        if case .skip(let reason) = deps.policy.decision(for: context) {
            throw LiveContextError.blocked(reason: reason.rawValue)
        }
    }

    private func captureDisplays(frontmostPid: pid_t?) async throws -> ScreenCapture {
        try await deps.screens.captureAll(
            excludingBundleIds: deps.policy.excludedBundleIds.union(deps.alwaysExcludedBundleIds),
            targetHeight: targetHeight, frontmostPid: frontmostPid
        )
    }

    private func recognize(_ jpeg: Data, limit: Int) async -> String {
        guard let result = try? await deps.ocr.recognize(jpeg: jpeg) else { return "" }
        let text = result.lines.filter { $0.confidence >= 0.3 }.map(\.text).joined(separator: "\n")
        // 与抽取层一致：屏幕文字里的凭据先脱敏。
        return String(SecretRedactor.redact(text).text.prefix(limit))
    }

    private static func focusFrame(_ capture: ScreenCapture) -> CapturedFrame? {
        capture.frames.first { $0.displayId == capture.focusDisplayId } ?? capture.frames.first
    }

    private static func encode(
        _ image: CGImage, scope: ScreenScope, at time: Date, maxHeight: Int, reused: Bool
    ) throws -> ScreenImage {
        let scaled = scale(image, maxHeight: maxHeight)
        guard let jpeg = try? JPEGEncoder.encode(scaled, quality: 0.8) else {
            throw LiveContextError.unavailable("encode failed")
        }
        return ScreenImage(
            jpeg: jpeg, perceptualHash: ImageHashing.dHash(scaled), scope: scope, capturedAt: time,
            reusedBackgroundFrame: reused
        )
    }

    static func scale(_ image: CGImage, maxHeight: Int) -> CGImage {
        guard image.height > maxHeight, maxHeight > 0 else { return image }
        let ratio = Double(maxHeight) / Double(image.height)
        let width = max(1, Int(Double(image.width) * ratio))
        guard let ctx = CGContext(
            data: nil, width: width, height: maxHeight, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return image }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: maxHeight))
        return ctx.makeImage() ?? image
    }
}
