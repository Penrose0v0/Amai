// 只按需导入：AmaiCore 的 `Observation` 类型会与 @Observable 宏依赖的 Observation 模块同名冲突。
import enum AmaiCore.AmaiLog
import struct AmaiCore.AmaiPaths
import AmaiPerception
import AppKit
import Foundation
import Observation

/// 菜单栏 UI 的状态源。只调用 PerceptionCoordinator 的公开接口。
@MainActor
@Observable
final class AppModel {
    private(set) var status: PerceptionStatus?
    private(set) var startupError: String?
    private(set) var configWarning: String?

    private let paths: AmaiPaths?
    private let coordinator: PerceptionCoordinator?
    private var pollTask: Task<Void, Never>?
    private let log = AmaiLog.logger("app")

    init() {
        var paths: AmaiPaths?
        var coordinator: PerceptionCoordinator?
        var configWarning: String?
        var startupError: String?
        do {
            let resolved = try AmaiPaths.standard()
            try resolved.ensureDirectories()
            let loaded = ConfigStore.load(from: resolved.config)
            paths = resolved
            configWarning = loaded.error
            coordinator = try PerceptionCoordinator(paths: resolved, configuration: loaded.configuration)
        } catch {
            startupError = "初始化失败：\(error)"
            AmaiLog.logger("app").error("startup failed: \(String(describing: error), privacy: .public)")
        }
        self.paths = paths
        self.coordinator = coordinator
        self.configWarning = configWarning
        self.startupError = startupError
        startPolling()
    }

    // MARK: - Actions

    func start() {
        Task { await coordinator?.start(); await refresh() }
    }

    func pause() {
        Task { await coordinator?.pause(); await refresh() }
    }

    func resume() {
        Task { await coordinator?.resume(); await refresh() }
    }

    /// 退出前先停止采集，让写入中的视频分段正常收尾。
    func quit() {
        Task {
            await coordinator?.stop()
            NSApplication.shared.terminate(nil)
        }
    }

    func requestScreenRecording() {
        if !ScreenRecordingPermission.request() {
            ScreenRecordingPermission.openSystemSettings()
        }
    }

    func openSystemSettings() {
        ScreenRecordingPermission.openSystemSettings()
    }

    func revealRawFolder() {
        guard let paths else { return }
        NSWorkspace.shared.activateFileViewerSelecting([paths.raw])
    }

    func revealConfig() {
        guard let paths else { return }
        NSWorkspace.shared.activateFileViewerSelecting([paths.config])
    }

    // MARK: - Polling

    private func startPolling() {
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func refresh() async {
        guard let coordinator else { return }
        status = await coordinator.status()
    }
}
