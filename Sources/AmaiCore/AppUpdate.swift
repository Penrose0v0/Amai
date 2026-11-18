import Foundation

/// 新版本检查与 Homebrew 升级用到的纯逻辑（网络请求与界面在 App 中）。
///
/// Amai 通过 Homebrew cask 分发（docs/release.md），自身不下载或替换程序文件：
/// 发现新版本后由用户确认，退出 Amai，再由一个独立的 shell 运行 `brew upgrade --cask amai` 并重新打开 App。
/// cask 的 `uninstall quit` 会在升级时退出正在运行的 Amai，所以升级不能在 Amai 进程内等待完成。
public enum AppUpdate {
    /// GitHub 上 Amai 最新正式版本（不含草稿与预发布）的接口。只读取公开的版本号，不发送任何用户数据。
    public static let latestReleaseAPI = URL(string: "https://api.github.com/repos/Penrose0v0/Amai/releases/latest")!
    public static let releasesPage = URL(string: "https://github.com/Penrose0v0/Amai/releases/latest")!
    public static let caskName = "amai"
    public static let upgradeCommand = "brew upgrade --cask \(caskName)"

    /// 去掉前导 "v" 与空白："v0.2.0" → "0.2.0"。
    public static func normalize(_ version: String) -> String {
        var text = version.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.first == "v" || text.first == "V" { text.removeFirst() }
        return text
    }

    /// 按数字逐段比较（"0.10.0" 比 "0.9.9" 新；字符串比较会弄错）。非数字段按 0 处理。
    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = normalize(candidate).split(separator: ".").map { Int($0) ?? 0 }
        let b = normalize(current).split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// 从 GitHub "latest release" 的响应中取出版本号；草稿、预发布或格式不对时返回 nil。
    public static func latestVersion(fromGitHubRelease data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = object["tag_name"] as? String,
              object["draft"] as? Bool != true, object["prerelease"] as? Bool != true
        else { return nil }
        let version = normalize(tag)
        return version.split(separator: ".").allSatisfy { Int($0) != nil } && !version.isEmpty ? version : nil
    }

    // MARK: - Homebrew

    /// 本机的 brew（Apple Silicon 在 /opt/homebrew，Intel 在 /usr/local）。
    public static func brewPath(fileManager: FileManager = .default) -> String? {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first { fileManager.isExecutableFile(atPath: $0) }
    }

    /// 正在运行的这份 Amai 是否由 Homebrew 安装：装在「应用程序」文件夹，且 Caskroom 中有 amai。
    /// 开发构建（.build/Amai.app）与手动下载的副本不能用 brew 升级。
    public static func isHomebrewInstall(bundlePath: String, brewPath: String, fileManager: FileManager = .default) -> Bool {
        let parent = URL(fileURLWithPath: bundlePath).deletingLastPathComponent().standardizedFileURL.path
        let applications = ["/Applications", (NSHomeDirectory() as NSString).appendingPathComponent("Applications")]
        guard applications.contains(parent) else { return false }
        let prefix = URL(fileURLWithPath: brewPath).deletingLastPathComponent().deletingLastPathComponent()
        return fileManager.fileExists(atPath: prefix.appendingPathComponent("Caskroom/\(caskName)").path)
    }

    /// 升级脚本，参数依次为 brew、日志文件、结果文件、open 命令、App 路径（作为位置参数传入，不拼接进脚本，避免引号问题）。
    /// 先等 Amai 退出，再升级；无论成败都重新打开 App（失败时打开的是旧版本，由它报告失败原因）。
    /// brew 的输出写入日志文件而不是管道：Amai 已经退出，没有进程读取管道。
    public static let upgradeScript = """
        sleep 1
        "$1" upgrade --cask \(caskName) >"$2" 2>&1
        printf '%s' "$?" >"$3"
        "$4" "$5"
        """

    /// 升级前记下的状态，Amai 重新打开后据此判断升级结果。
    public struct Pending: Codable, Equatable, Sendable {
        public var fromVersion: String
        public var targetVersion: String
        public init(fromVersion: String, targetVersion: String) {
            self.fromVersion = fromVersion
            self.targetVersion = targetVersion
        }
    }

    public enum Outcome: Equatable, Sendable {
        case succeeded(version: String)
        /// 升级失败；detail 是 brew 输出的最后几行（可能为空）。
        case failed(detail: String)
    }

    /// 根据升级前的记录、脚本写下的退出码与 brew 日志判断结果。
    /// 退出码缺失（脚本没跑完）或非零都算失败；退出码为 0 但版本没有变新也算失败（例如 tap 还没有新版本）。
    public static func outcome(pending: Pending, exitCode: String?, log: String?, runningVersion: String) -> Outcome {
        if exitCode?.trimmingCharacters(in: .whitespacesAndNewlines) == "0", !isNewer(pending.targetVersion, than: runningVersion) {
            return .succeeded(version: runningVersion)
        }
        let lines = (log ?? "").split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return .failed(detail: lines.suffix(3).joined(separator: "\n"))
    }
}
