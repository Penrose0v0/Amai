# iOS 屏幕感知：调研与 PoC

> 状态：调研与 PoC 已完成（2026-11-21），**实机测量尚未进行**。本文属于参考资料，不构成架构决策；测量完成后再写 ADR。
> PoC 工程：`Apps/AmaiIOSPoC/`，独立于 Swift Package，不影响 macOS 构建。

## 1. 两条公开途径

| | ReplayKit 广播上传扩展 | ScreenCaptureKit |
|---|---|---|
| 系统版本 | iOS 18–26 可用；iOS 27 SDK 中标为废弃但仍可运行 | iOS 27 起 |
| 运行位置 | 独立的扩展进程，内存上限约 50 MB | App 进程内 |
| 开始方式 | 用户在系统的广播选择器里确认 | 用户在系统的内容选择器（`SCContentSharingPicker`）里确认 |
| 跨 App | 是（整个屏幕） | 据资料是，需声明后台模式 `screen-capture` |
| 与主 App 交换数据 | App Group 容器 | 不需要 |

两者都必须由用户每次手动开始，没有 macOS 那种"授权一次、后台定时截图"的方式。

## 2. 信息的可靠程度

**已在本机核对**

- Xcode 26.5 的 iOS SDK 里没有 `ScreenCaptureKit.framework`，只有 ReplayKit。
- 测试机是 iOS 26.6.2，因此目前只能测 ReplayKit 这条路径。
- PoC 在真机 SDK 与模拟器下都能编译；模拟器里 App 能启动，App Group 容器与日志读写正常。模拟器不支持广播，采集本身没有运行过。

**来自第三方资料，未核对**（没有找到 Apple 官方文档；所引项目都注明没有在真机上运行过）

- iOS 27 提供 `SCStream`、`SCStreamConfiguration`、`SCContentFilter`、`SCContentSharingPicker`。
- 后台采集需要 `UIBackgroundModes` 里的 `screen-capture`；缺少时流会以"缺少后台模式"的错误停止（错误码有 -3824 的说法）。
- iOS 上没有 `minimumFrameInterval`、`queueDepth`、`pixelFormat`（两处资料一致，一处示例代码相反）。
- 选择器停留 60 秒会超时；麦克风只能由用户在选择器里打开。
- ScreenCaptureKit 不在模拟器 SDK 里。
- 没有任何资料给出锁屏、来电、受保护内容、系统指示器、授权是否跨启动保留，以及 CPU / 电量的数据。

来源：[LiveKit iOS 屏幕共享文档](https://github.com/livekit/client-sdk-swift/blob/main/Docs/ios-screen-sharing.md)、[LiveKit PR #1135](https://github.com/livekit/client-sdk-swift/pull/1135)、[AI-Notepad PR #163](https://github.com/senoldogann/AI-Notepad/pull/163)、[ios-ascii-screenshot PR #1](https://github.com/smolfroggo/ios-ascii-screenshot/pull/1)、[Forasoft 博客](https://www.forasoft.com/blog/article/how-to-implement-screen-sharing-in-ios-1193)；ReplayKit 的 50 MB 上限见 [Apple 开发者论坛](https://developer.apple.com/forums/thread/651367)。

## 3. PoC 做了什么

- `Broadcast/SampleHandler.swift`：广播扩展。收到视频帧后交给 `FrameSink`；记录开始、暂停、恢复、结束、锁屏 / 解锁，以及系统是否告知前台应用。音频只计数。
- `Shared/FrameSink.swift`：按间隔（1 / 5 / 10 / 30 秒）抽样，长边缩到 1280，dHash 去重，存 JPEG。两帧相隔超过 3 秒记一条 `frameGap`。
- `Shared/PoCStore.swift`：App Group 容器里的截图目录与测量日志（JSONL）。每 30 秒记录一次帧数、内存、电量、热状态，没有新帧时也记录。
- `App/`：开始广播的按钮、最近读数、最近截图、事件列表、导出日志、一键清除。
- `App/SCKCapture.swift`：iOS 27 路径，**未编译**，由 `AMAI_POC_SCK` 开关隔离，用同一个 `FrameSink`。

隐私：截图只在本机 App Group 容器，最多 300 张、24 小时；日志不含屏幕内容；不联网；不采集麦克风。
锁屏检测用的是系统的 Darwin 通知，不是公开 API，只用于 PoC 诊断。

## 4. 运行

1. `Apps/AmaiIOSPoC/Config/Local.xcconfig` 里填 `DEVELOPMENT_TEAM`（参考 `Local.xcconfig.example`）；bundle 前缀默认 `com.amai.ios`，与团队下已有的 id 冲突时改 `AMAI_BUNDLE_PREFIX`。
2. 用 Xcode 打开 `AmaiIOSPoC.xcodeproj`，选真机运行 `AmaiPoC`。首次签名时 Xcode 会注册 App Group。
3. 点界面里的广播按钮 → 选 "Amai PoC" → 开始直播。

测 iOS 27 路径：装 Xcode 27，按 `App/SCKCapture.swift` 顶部的说明打开开关并修正编译错误。

## 5. 实机测量清单

每项做完后导出日志，把结论填进下表。

| # | 项目 | 做法 | 看什么 | ReplayKit（iOS 26） | SCK（iOS 27） |
|---|---|---|---|---|---|
| 1 | 跨 App 捕获 | 开始后切到主屏幕、Safari、微信、相机 | 截图里是否是那些 App 的画面；`applicationInfo` 是否出现及其内容 | 待测 | 待测 |
| 2 | 主 App 在后台 | 开始后把 PoC 划到后台 10 分钟；再从多任务里划掉 PoC | `stats` 是否持续；`received` 是否增长 | 待测 | 待测 |
| 3 | 静止画面 | 停在一个不动的页面 2 分钟 | `frameGap` 的时长；系统是否只在画面变化时送帧 | 待测 | 待测 |
| 4 | 锁屏 | 锁屏 2 分钟再解锁；另测自动熄屏 | `deviceLocked` 之后是否 `broadcastFinished`，还是只停帧；解锁后是否自动恢复 | 待测 | 待测 |
| 5 | 中断 | 来电、闹钟、开始系统录屏、打开相机 | 是否结束广播 | 待测 | 待测 |
| 6 | 受保护内容 | 播放有版权保护的视频、打开密码输入框、银行类 App | 截图是黑屏、被跳过还是照常 | 待测 | 待测 |
| 7 | 权限与指示 | 记录每次开始需要的操作步数、系统显示的指示（状态栏 / 灵动岛） | 重启 App、重启手机之后是否要重新确认 | 待测 | 待测 |
| 8 | 内存 | 间隔 1 秒、横竖屏切换、连续 30 分钟 | `footprintMB` 峰值；是否无 `broadcastFinished` 就没了读数（被系统终止） | 待测 | 不适用 |
| 9 | 功耗 | 满电、不充电、亮度固定，间隔 10 秒正常使用 1 小时；同条件不开广播再测 1 小时 | 两次 `battery` 的降幅之差；`thermal` 是否升高 | 待测 | 待测 |
| 10 | 长时间 | 开着广播正常用半天 | 广播在什么情况下自己结束 | 待测 | 待测 |

功耗更细的数据用 Xcode 的 Instruments（Energy Log）或"设置 → 电池"里按 App 的统计补充。

## 6. 测完要回答的问题

- 用户每次手动开始、且有常驻的录制指示，这种形态能不能算 Ambient？能接受的话每天要开始几次。
- 锁屏之后要不要用户重新开始。
- 能不能拿到前台应用的标识（决定 iOS 上的按应用排除与活动识别怎么做）。
- 50 MB 之内只做抽样和存图够不够；OCR 与抽取放回主 App 时主 App 什么时候有机会运行。
- 最低支持 iOS 18 的前提下，是 ReplayKit 与 ScreenCaptureKit 两套都做，还是只做一套。
