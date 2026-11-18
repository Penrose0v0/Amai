import enum AmaiCore.AmaiLog
import enum AmaiCore.AppUpdate
import AppKit
import Foundation
import Observation

/// 新版本提示与 Homebrew 升级（参考 Eira 的做法）。
///
/// - 启动后稍等片刻检查一次，之后每 6 小时检查一次 GitHub 上的最新正式版本；只读取公开的版本号，失败时静默跳过。
/// - 有新版本时菜单栏图标变蓝，菜单顶部出现"更新到 vX"。
/// - Homebrew 安装的副本：确认后由 `AppModel` 收尾退出，独立的 shell 运行 `brew upgrade --cask amai` 并重新打开 App；
///   重新打开后读取升级记录，失败时在菜单中显示原因。其他副本（开发构建、手动下载）打开下载页面。
@MainActor
@Observable
final class UpdateController {
    /// 比正在运行的版本更新的正式版本号；没有新版本、未检查或检查失败时为 nil。
    private(set) var availableVersion: String?
    /// 上一次升级失败的说明（Amai 重新打开后从升级记录中读出）。
    private(set) var failure: String?

    static let checkInterval: Duration = .seconds(6 * 3600)
    static let firstCheckDelay: Duration = .seconds(15)

    let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    private var loop: Task<Void, Never>?

    /// 升级记录放在本用户的临时目录：跨 App 重启保留，重启电脑后由系统清理。
    private static let directory = FileManager.default.temporaryDirectory.appendingPathComponent("amai-update", isDirectory: true)
    private static var pendingFile: URL { directory.appendingPathComponent("pending.json") }
    private static var statusFile: URL { directory.appendingPathComponent("exit-code") }
    private static var logFile: URL { directory.appendingPathComponent("brew.log") }

    func start() {
        readPreviousUpgrade()
        loop?.cancel()
        loop = Task { [weak self] in
            try? await Task.sleep(for: Self.firstCheckDelay)
            while !Task.isCancelled {
                await self?.check()
                try? await Task.sleep(for: Self.checkInterval)
            }
        }
    }

    /// 检查一次。网络错误、限流或响应格式不对都只是跳过，保留上一次的结果。
    func check() async {
        var request = URLRequest(url: AppUpdate.latestReleaseAPI, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let latest = AppUpdate.latestVersion(fromGitHubRelease: data)
        else {
            AmaiLog.logger("update").info("update check skipped")
            return
        }
        availableVersion = AppUpdate.isNewer(latest, than: currentVersion) ? latest : nil
    }

    /// 能否用 Homebrew 原地升级这份 App；不能时返回 nil。
    var brewForThisInstall: String? {
        guard let brew = AppUpdate.brewPath(),
              AppUpdate.isHomebrewInstall(bundlePath: Bundle.main.bundlePath, brewPath: brew)
        else { return nil }
        return brew
    }

    /// 记下升级前的状态并启动独立的升级 shell。调用方随后立即退出 Amai。
    func launchUpgrade(brew: String, target: String) throws {
        let fm = FileManager.default
        try? fm.removeItem(at: Self.directory)
        try fm.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        let pending = AppUpdate.Pending(fromVersion: currentVersion, targetVersion: target)
        try JSONEncoder().encode(pending).write(to: Self.pendingFile, options: .atomic)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", AppUpdate.upgradeScript, "amai-update",
                             brew, Self.logFile.path, Self.statusFile.path, "/usr/bin/open", Bundle.main.bundlePath]
        // 从 LaunchServices 启动的 App 只有最小的 PATH；brew 还要调用 git、curl 等。
        var environment = ProcessInfo.processInfo.environment
        let brewDirectory = URL(fileURLWithPath: brew).deletingLastPathComponent().path
        environment["PATH"] = "\(brewDirectory):/usr/bin:/bin:/usr/sbin:/sbin"
        if environment["HOME"] == nil { environment["HOME"] = NSHomeDirectory() }
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        AmaiLog.logger("update").info("upgrade to \(target, privacy: .public) started")
    }

    /// 读取上一次升级的结果（如果有），然后删除记录。
    private func readPreviousUpgrade() {
        defer { try? FileManager.default.removeItem(at: Self.directory) }
        guard let data = try? Data(contentsOf: Self.pendingFile),
              let pending = try? JSONDecoder().decode(AppUpdate.Pending.self, from: data)
        else { return }
        let exitCode = try? String(contentsOf: Self.statusFile, encoding: .utf8)
        let log = try? String(contentsOf: Self.logFile, encoding: .utf8)
        switch AppUpdate.outcome(pending: pending, exitCode: exitCode, log: log, runningVersion: currentVersion) {
        case .succeeded(let version):
            AmaiLog.logger("update").info("upgraded \(pending.fromVersion, privacy: .public) → \(version, privacy: .public)")
        case .failed(let detail):
            AmaiLog.logger("update").error("upgrade to \(pending.targetVersion, privacy: .public) failed")
            failure = detail.isEmpty
                ? String(localized: "更新到 v\(pending.targetVersion) 失败")
                : String(localized: "更新到 v\(pending.targetVersion) 失败：\(detail)")
        }
    }

    func dismissFailure() { failure = nil }

    /// 隔离预览用：不联网，直接显示"有新版本"的菜单栏与菜单（预览中不能真正升级）。
    func showAvailableForPreview(_ version: String) {
        availableVersion = AppUpdate.normalize(version)
    }

    func openReleasesPage() {
        NSWorkspace.shared.open(AppUpdate.releasesPage)
    }
}
