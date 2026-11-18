import Foundation
import Testing
@testable import AmaiCore

@Suite("App update")
struct AppUpdateTests {
    @Test("versions compare numerically, ignoring a leading v")
    func versionComparison() {
        #expect(AppUpdate.normalize(" v0.2.0 ") == "0.2.0")
        #expect(AppUpdate.isNewer("0.2.0", than: "0.1.0"))
        #expect(AppUpdate.isNewer("v0.10.0", than: "0.9.9"))
        #expect(AppUpdate.isNewer("1.0", than: "0.9.9"))
        #expect(!AppUpdate.isNewer("0.1.0", than: "0.1.0"))
        #expect(!AppUpdate.isNewer("0.1", than: "0.1.0"))
        #expect(!AppUpdate.isNewer("0.1.0", than: "0.2.0"))
    }

    @Test("only published releases with a numeric tag count")
    func releaseParsing() {
        func parse(_ json: String) -> String? { AppUpdate.latestVersion(fromGitHubRelease: Data(json.utf8)) }
        #expect(parse(#"{"tag_name":"v0.2.0","draft":false,"prerelease":false}"#) == "0.2.0")
        #expect(parse(#"{"tag_name":"0.3.1"}"#) == "0.3.1")
        #expect(parse(#"{"tag_name":"v0.2.0","prerelease":true}"#) == nil)
        #expect(parse(#"{"tag_name":"v0.2.0","draft":true}"#) == nil)
        #expect(parse(#"{"tag_name":"nightly"}"#) == nil)
        #expect(parse(#"{"message":"API rate limit exceeded"}"#) == nil)
        #expect(parse("not json") == nil)
    }

    @Test("only a copy in Applications with a Caskroom entry is Homebrew-managed")
    func homebrewDetection() throws {
        let prefix = FileManager.default.temporaryDirectory.appendingPathComponent("amai-brew-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: prefix) }
        let brew = prefix.appendingPathComponent("bin/brew").path
        #expect(!AppUpdate.isHomebrewInstall(bundlePath: "/Applications/Amai.app", brewPath: brew))
        try FileManager.default.createDirectory(at: prefix.appendingPathComponent("Caskroom/amai"), withIntermediateDirectories: true)
        #expect(AppUpdate.isHomebrewInstall(bundlePath: "/Applications/Amai.app", brewPath: brew))
        #expect(AppUpdate.isHomebrewInstall(bundlePath: NSHomeDirectory() + "/Applications/Amai.app", brewPath: brew))
        #expect(!AppUpdate.isHomebrewInstall(bundlePath: "/Users/someone/Amai/.build/Amai.app", brewPath: brew))
        #expect(!AppUpdate.isHomebrewInstall(bundlePath: "/Users/someone/Downloads/Amai.app", brewPath: brew))
    }

    /// 用假的 brew 与 open 实际运行升级脚本：记录退出码与输出，并且无论成败都重新打开 App。
    @Test("the upgrade script records the result and reopens the app", arguments: [0, 1])
    func upgradeScript(brewExit: Int32) throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("amai-update-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        func executable(_ name: String, _ body: String) throws -> String {
            let url = dir.appendingPathComponent(name)
            try ("#!/bin/sh\n" + body).write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            return url.path
        }
        let brew = try executable("brew", "echo \"args: $*\"\necho 'Error: something went wrong' >&2\nexit \(brewExit)\n")
        let open = try executable("open", "echo \"$1\" > \"\(dir.path)/opened\"\n")
        let log = dir.appendingPathComponent("brew log.txt").path
        let status = dir.appendingPathComponent("exit code").path
        let app = "/Applications/Amai \"test\".app"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", AppUpdate.upgradeScript, "amai-update", brew, log, status, open, app]
        try process.run()
        process.waitUntilExit()

        #expect(try String(contentsOfFile: status, encoding: .utf8) == "\(brewExit)")
        let output = try String(contentsOfFile: log, encoding: .utf8)
        #expect(output.contains("args: upgrade --cask amai"))
        #expect(output.contains("Error: something went wrong"))
        #expect(try String(contentsOfFile: dir.appendingPathComponent("opened").path, encoding: .utf8) == app + "\n")
    }

    @Test("the outcome needs exit code 0 and a newer running version")
    func outcome() {
        let pending = AppUpdate.Pending(fromVersion: "0.1.0", targetVersion: "0.2.0")
        #expect(AppUpdate.outcome(pending: pending, exitCode: "0", log: "", runningVersion: "0.2.0") == .succeeded(version: "0.2.0"))
        #expect(AppUpdate.outcome(pending: pending, exitCode: "0\n", log: nil, runningVersion: "0.2.1") == .succeeded(version: "0.2.1"))
        // brew 报告成功但仍是旧版本（例如 tap 里还没有新版本）。
        #expect(AppUpdate.outcome(pending: pending, exitCode: "0", log: "Warning: Not upgrading amai, the latest version is already installed", runningVersion: "0.1.0")
            == .failed(detail: "Warning: Not upgrading amai, the latest version is already installed"))
        // 脚本没跑完，没有退出码。
        #expect(AppUpdate.outcome(pending: pending, exitCode: nil, log: nil, runningVersion: "0.1.0") == .failed(detail: ""))
        // 只保留最后三行非空输出。
        let log = "==> Upgrading 1 outdated package\n\nline a\nline b\nError: Download failed\n"
        #expect(AppUpdate.outcome(pending: pending, exitCode: "1", log: log, runningVersion: "0.1.0")
            == .failed(detail: "line a\nline b\nError: Download failed"))
    }
}
