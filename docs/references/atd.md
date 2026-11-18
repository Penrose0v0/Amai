# AtD（JUNERDD/Atd）

> 基本信息（截至 2026-11-18）
>
> | 项目 | 内容 |
> |---|---|
> | 地址 | https://github.com/JUNERDD/Atd |
> | 许可证 | MIT |
> | 参考范围 | 只参考 macOS 端 `apps/macos/Sources/AIShell/Selection/` 与 `AIComputerDriver/AX/WebAccessibility.swift`（读取的提交 `e9d0f21`） |

本文只记录 Amai 选区读取借鉴的部分；AtD 的其它功能（自动弹出的选区工具栏、打字动画、WPS 插件等）不在参考范围内，Amai 也不实现自动弹出或持续监听选区。

## 借鉴的做法

- **多级读取**（`SelectionReader`）：每个控件依次尝试 `AXSelectedText`、Web Text Marker、`AXSelectedTextRange` + `AXStringForRange`、`AXValue` 按区间截取。Text Marker 放在 `AXStringForRange` 之前，因为 Chromium 的后者会丢掉 U+FFFC 占位符。
- **层级搜索**：焦点 → 前 20 个子控件 → 最多 10 层父控件；控件明确报告"空选区"时停止。
- **中止与时限**：单条消息 250 ms；任何一条 `cannotComplete` 视为应用无响应，放弃整次读取；外层还有总时限，迟到的结果丢弃。
- **读不到的原因**：区分"原生文本控件选区为空"（不复制，否则只会"嘟"一声）、密码框、无响应、"看不出"（只有这种才复制）。
- **复制回退**（`CopySelection` / `CopyFallback`）：按快捷键 ⌘C 在菜单栏找到"拷贝"并经 AX 执行（不受按住的修饰键影响；AtD 在没有菜单项时还会发 ⌘C，Amai 不发）；剪贴板完整快照，只认 changeCount 变化后的内容；超时到达的复制也会恢复剪贴板。
- **Electron 与 `AXManualAccessibility`**：AtD 记录了 VS Code / Cursor 会把该属性当作屏幕阅读器在场（弹窗、切换编辑器模式、写用户设置），改为读应用的 `AXRole` 唤醒基本模式。

## 与 Amai 的差异

- AtD 有全局输入 / 剪贴板仲裁器（`DeviceArbiter`）；Amai 只读选区，只有一个主线程上的剪贴板互斥锁保护复制回退。
- AtD 支持把结果写回原文；Amai 不写回（替换原文功能已移除）。
- AtD 对表格单元格选区、WPS 等有专门处理；Amai 暂未实现。
- Amai 对网页里的密码框额外检查：焦点常报告为 `AXWebArea`，选中后还能读到等长掩码，所以安全输入开启或 Text Marker 起点在密码框里时一律拒绝（实测 Safari / Chrome）。
