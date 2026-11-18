import AmaiAssistant
import AppKit
import SwiftUI
import QuartzCore

/// Borderless NSPanel must explicitly opt in to becoming key, otherwise the
/// text field inside won't receive keystrokes.
private final class FloatingChatPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class ChatWindowController {
    private static let frameKey = "Amai.ChatWindow.Frame"
    private static let defaultSize = NSSize(width: 460, height: 580)
    private static let minSize = NSSize(width: 380, height: 400)
    private static let cornerRadius: CGFloat = 20

    // Show: scale pop (peak → dip → 1.0) + fade in. Close: scale (1.0 → end) + fade out.
    private static let showDuration: CFTimeInterval = 0.30
    private static let hideDuration: CFTimeInterval = 0.12
    private static let popPeakScale: CGFloat = 1.03
    private static let popDipScale: CGFloat = 0.99
    private static let closeEndScale: CGFloat = 1.02

    private let viewModel: ChatViewModel
    let window: NSPanel
    private var observers: [NSObjectProtocol] = []
    private var workspaceObserver: NSObjectProtocol?
    private var contextRefreshTask: Task<Void, Never>?

    /// While we drive the show/hide animation we move the window ourselves —
    /// suppress the save observer so the transient frames don't overwrite the
    /// user-chosen position.
    private var isAnimating = false

    /// Authoritative "should the window be visible" state. We can't rely on
    /// `window.isVisible` during animations or transient key-status flicker.
    private var isShowing = false

    /// Deferred-close task. resignKey schedules a close ~300ms in the future;
    /// a Space transition cancels it (we ride the transition, then silently
    /// disappear on the new Space).
    private var pendingCloseTask: Task<Void, Never>?

    /// Static-image window shown during the dismiss animation (see `close()`).
    private var dismissOverlay: NSWindow?

    init(
        viewModel: ChatViewModel,
        onOpenSource: @escaping (MemorySource) -> Void = { _ in },
        onOpenSettings: @escaping () -> Void = {}
    ) {
        self.viewModel = viewModel

        let initialFrame = Self.loadSavedFrame() ?? Self.defaultBottomRightFrame()

        let panel = FloatingChatPanel(
            contentRect: initialFrame,
            styleMask: [.nonactivatingPanel, .borderless, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        // .moveToActiveSpace: when we orderFront, the window moves to whatever
        // Space is currently active. When the user switches Spaces *without*
        // us calling orderFront, the window stays put on the old Space —
        // which means it rides the Space transition naturally (it's captured
        // in the old Space's snapshot) and is *not* visible on the new Space.
        // The next ⌘⇧Space invocation brings it to the active Space.
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.minSize = Self.minSize
        panel.animationBehavior = .none

        panel.contentView = Self.makeContentView(viewModel: viewModel, onOpenSource: onOpenSource, onOpenSettings: onOpenSettings)
        // NSGlassEffectView can flip window flags when it installs; re-assert.
        panel.isOpaque = false
        panel.backgroundColor = .clear

        self.window = panel

        observers.append(
            NotificationCenter.default.addObserver(
                forName: NSWindow.didMoveNotification,
                object: panel,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.saveFrame() }
            }
        )
        observers.append(
            NotificationCenter.default.addObserver(
                forName: NSWindow.didResizeNotification,
                object: panel,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.saveFrame() }
            }
        )

        // Spotlight-style auto-dismiss: when the window loses key focus
        // (user clicked another app/window), close it — but defer the close
        // so a transient resignKey during a Space transition can be cancelled.
        observers.append(
            NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification,
                object: panel,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.handleResignKey() }
            }
        )

        // Refresh the "Watching X" indicator when the user switches to a
        // different app while the popover is open (mainly matters for
        // pinned mode — unpinned mode has already started auto-closing).
        let ourPID = NSRunningApplication.current.processIdentifier
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication,
                  app.processIdentifier != ourPID
            else { return }
            MainActor.assumeIsolated {
                guard let self, self.isShowing else { return }
                self.viewModel.refreshContextIfChanged()
            }
        }
    }

    /// One Spotlight-style Liquid Glass panel (macOS 26+): the whole ChatView —
    /// header, chat area, and input row — hosted inside a single
    /// `NSGlassEffectView`. One glass surface renders one consistent tone, unlike
    /// two separate cards that each adapt light/dark to their own content. The
    /// rounded clip removes the glass's drop shadow. On older systems ChatView's
    /// `chatCardSurface` draws its own `VisualEffectBlur` background.
    private static func makeContentView(
        viewModel: ChatViewModel,
        onOpenSource: @escaping (MemorySource) -> Void,
        onOpenSettings: @escaping () -> Void
    ) -> NSView {
        let host = NSHostingView(
            rootView: ChatView(viewModel: viewModel, onOpenSource: onOpenSource, onOpenSettings: onOpenSettings)
                .followsInterfaceLanguage()
        )
        let content: NSView
        if #available(macOS 26.0, *) {
            content = PanelGlass.glassCard(host)
        } else {
            content = host
        }
        // Lock the panel to a dark appearance. The glass surface is dark in both
        // system themes, so adaptive semantic text (.primary / .secondary) would
        // resolve to near-black — unreadable — under a light system theme. Pinning
        // darkAqua keeps every label light-on-dark regardless of the OS setting.
        content.appearance = NSAppearance(named: .darkAqua)
        return content
    }

    private func handleResignKey() {
        guard isShowing, !isAnimating else { return }
        // User has opted into "stay open" mode — only ESC / X dismiss.
        if viewModel.isPinned { return }
        // If anything else inside Eira has key — history popover, an alert, the
        // Settings/onboarding window — the user is still inside the app; don't
        // yank the chat out from under them. `NSApp.keyWindow` is process-scoped,
        // so a non-nil value means another Eira window owns key.
        if NSApp.keyWindow != nil { return }
        // Close immediately. The old 120ms defer left the window resigned-key —
        // and NSGlassEffectView repaints its inactive (opaque) appearance while
        // not key — visibly opaque for that whole delay, which read as a stutter
        // before it hid. Hiding right away never shows that inactive frame (the
        // X button was always clean for the same reason: it orderOut while key).
        pendingCloseTask?.cancel()
        pendingCloseTask = nil
        close()
    }

    // 控制器与应用同寿命（由 AssistantController 持有），不需要在 deinit 里移除观察者。

    var isVisible: Bool { isShowing }

    func toggle() {
        pendingCloseTask?.cancel()
        pendingCloseTask = nil
        if isShowing {
            // Pinned window may live on a Space the user isn't currently in.
            // Treat the shortcut as "bring Eira here" instead of "dismiss" so
            // it takes one press, not two, to summon onto the active Space.
            // `.moveToActiveSpace` (set in collectionBehavior) does the heavy
            // lifting once we orderFront.
            if !window.isOnActiveSpace {
                presentAtCurrentFrame()
                return
            }
            // Same Space but a different physical display — relocate.
            if let target = Self.screenUnderMouse(), target != window.screen {
                relocate(to: target)
                return
            }
            close()
        } else {
            show()
        }
    }

    private static func screenUnderMouse() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) }
    }

    /// Poll metadata every ~1.5s while the window is visible on the active
    /// Space. Catches changes the app-activation observer misses, mainly
    /// browser tab switches — same app stays frontmost so no
    /// `didActivateApplication` fires, but the window title changes. The
    /// poll is gated on `isOnActiveSpace` so it doesn't burn AX calls when
    /// the user can't see the indicator anyway.
    private func startContextRefreshLoop() {
        contextRefreshTask?.cancel()
        contextRefreshTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(1500))
                guard let self, !Task.isCancelled else { return }
                guard self.isShowing else { return }
                guard self.window.isOnActiveSpace else { continue }
                self.viewModel.refreshContextIfChanged()
            }
        }
    }

    private func relocate(to screen: NSScreen) {
        let visible = screen.visibleFrame
        let size = window.frame.size
        let margin: CGFloat = 20
        let origin = NSPoint(
            x: visible.maxX - size.width - margin,
            y: visible.minY + margin
        )
        window.setFrame(NSRect(origin: origin, size: size), display: true)
        presentAtCurrentFrame()
    }

    func show() {
        guard !isShowing else { return }
        isShowing = true
        // Resolve target frame: prefer saved, fall back to bottom-right default
        // if saved frame is off-screen (e.g. external monitor disconnected).
        let target: NSRect
        if let saved = Self.loadSavedFrame(), Self.frameIsOnScreen(saved) {
            target = saved
        } else {
            target = Self.defaultBottomRightFrame()
        }

        window.setFrame(target, display: false)
        presentAtCurrentFrame()
        viewModel.onPopoverOpened()
    }

    /// Order the window front at its current frame and play the show
    /// animation (scale pop + fade in). Shared by `show()` and by the
    /// pinned-window "summon to active Space / relocate to current screen"
    /// paths in `toggle()`, so all three feel the same.
    private func presentAtCurrentFrame() {
        isAnimating = true
        window.alphaValue = 0
        window.makeKeyAndOrderFront(nil)
        startContextRefreshLoop()

        window.contentView?.wantsLayer = true
        if let layer = window.contentView?.layer {
            let scaleAnim = CAKeyframeAnimation(keyPath: "transform")
            scaleAnim.values = [
                NSValue(caTransform3D: Self.centeredScale(Self.popPeakScale, in: layer)),
                NSValue(caTransform3D: Self.centeredScale(Self.popDipScale, in: layer)),
                NSValue(caTransform3D: Self.centeredScale(1.0, in: layer)),
            ]
            scaleAnim.keyTimes = [0.0, 0.55, 1.0]
            scaleAnim.duration = Self.showDuration
            scaleAnim.timingFunctions = [
                CAMediaTimingFunction(name: .easeOut),
                CAMediaTimingFunction(name: .easeInEaseOut),
            ]
            layer.add(scaleAnim, forKey: "popIn")
        }

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Self.showDuration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            ctx.allowsImplicitAnimation = true
            window.animator().alphaValue = 1
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                self?.isAnimating = false
            }
        })
    }

    func close() {
        guard isShowing else { return }
        isShowing = false
        contextRefreshTask?.cancel()
        contextRefreshTask = nil

        // Fade out by animating a static snapshot, not the real window:
        // NSGlassEffectView repaints opaque the moment its window is fading /
        // resigned, so a direct fade pops. We're called synchronously from the
        // dismiss trigger (before the glass repaints), so the snapshot captures
        // the live, active glass; we then hide the real window under an overlay
        // and fade the bitmap, which is perfectly smooth.
        let frame = window.frame
        guard let snapshot = onScreenSnapshot() else {
            window.orderOut(nil)
            return
        }
        isAnimating = true

        let overlay = NSWindow(
            contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false
        )
        overlay.isOpaque = false
        overlay.backgroundColor = .clear
        overlay.hasShadow = false
        overlay.level = window.level
        overlay.ignoresMouseEvents = true

        let imageView = NSImageView()
        imageView.wantsLayer = true
        imageView.imageScaling = .scaleAxesIndependently
        imageView.image = snapshot
        imageView.frame = NSRect(origin: .zero, size: frame.size)
        overlay.contentView = imageView

        // Overlay in front first, then hide the real window under it so its
        // opaque flicker (if any) is never visible.
        overlay.orderFront(nil)
        window.orderOut(nil)
        dismissOverlay = overlay

        guard let layer = imageView.layer else {
            finishDismiss()
            return
        }
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated { self?.finishDismiss() }
        }
        let scale = CABasicAnimation(keyPath: "transform")
        scale.fromValue = NSValue(caTransform3D: Self.centeredScale(1.0, in: layer))
        scale.toValue = NSValue(caTransform3D: Self.centeredScale(Self.closeEndScale, in: layer))
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1.0
        fade.toValue = 0.0
        let group = CAAnimationGroup()
        group.animations = [scale, fade]
        group.duration = Self.hideDuration
        group.timingFunction = CAMediaTimingFunction(name: .easeIn)
        group.fillMode = .forwards
        group.isRemovedOnCompletion = false
        layer.add(group, forKey: "dismiss")
        layer.opacity = 0
        CATransaction.commit()
    }

    /// Tear down the dismiss snapshot overlay once its fade finishes.
    private func finishDismiss() {
        dismissOverlay?.orderOut(nil)
        dismissOverlay = nil
        isAnimating = false
    }

    /// Capture what's currently on screen within the window's frame (the panel
    /// with its live glass, plus the desktop at its transparent edges) as a
    /// static image to fade on dismiss. Must be called synchronously while the
    /// glass is still active, before it repaints opaque.
    private func onScreenSnapshot() -> NSImage? {
        // Eira 用 CGWindowListCreateImage 截下面板做淡出动画；该接口在 macOS 15 SDK 中已不可用。
        // 返回 nil 时 `close()` 直接隐藏窗口，没有淡出。
        nil
    }

    private func saveFrame() {
        guard !isAnimating else { return }
        UserDefaults.standard.set(
            NSStringFromRect(window.frame),
            forKey: Self.frameKey
        )
    }

    private static func loadSavedFrame() -> NSRect? {
        guard let str = UserDefaults.standard.string(forKey: frameKey) else { return nil }
        let rect = NSRectFromString(str)
        guard rect.width > 0, rect.height > 0 else { return nil }
        return rect
    }

    private static func defaultBottomRightFrame() -> NSRect {
        let screen = NSScreen.main ?? NSScreen.screens.first!
        let visible = screen.visibleFrame
        let margin: CGFloat = 20
        let size = defaultSize
        return NSRect(
            x: visible.maxX - size.width - margin,
            y: visible.minY + margin,
            width: size.width,
            height: size.height
        )
    }

    /// Build a transform that scales by `s` around the layer's geometric center,
    /// regardless of where its anchorPoint sits (NSView-backed layers default
    /// to anchor (0, 0), so a plain `transform.scale` would visibly drift).
    private static func centeredScale(_ s: CGFloat, in layer: CALayer) -> CATransform3D {
        let b = layer.bounds
        let dx = b.midX - layer.anchorPoint.x * b.width
        let dy = b.midY - layer.anchorPoint.y * b.height
        var t = CATransform3DIdentity
        t = CATransform3DTranslate(t, dx * (1 - s), dy * (1 - s), 0)
        return CATransform3DScale(t, s, s, 1)
    }

    private static func frameIsOnScreen(_ rect: NSRect) -> Bool {
        for screen in NSScreen.screens where screen.visibleFrame.intersects(rect) {
            return true
        }
        return false
    }
}
