# Amai — Ambient Personal AI

在 macOS 上后台感知用户活动，抽取语义上下文，沉淀为用户可读、可编辑的 Markdown 长期记忆。

- 工程约束与 Agent 工作规范：[AGENTS.md](AGENTS.md)
- 产品定义：[docs/product.md](docs/product.md)
- 架构：[docs/architecture.md](docs/architecture.md)
- 记忆系统：[docs/memory.md](docs/memory.md)
- 路线图：[docs/roadmap.md](docs/roadmap.md)
- 决策记录：[docs/decisions/](docs/decisions/)
- 参考研究：[docs/references/](docs/references/)

## 开发

要求：macOS 15+、Xcode 26（含 Metal 工具链组件）、Swift 6.x。

```bash
swift build                  # 编译
swift test                   # 运行不依赖 MLX 权重的测试
./scripts/bundle.sh          # 组装 .build/Amai.app（含 mlx.metallib、签名）
open .build/Amai.app         # 运行（菜单栏应用）
```

直接 `swift run` 无法运行涉及 MLX 推理的代码路径（SwiftPM 不编译 Metal kernel），必须通过 `bundle.sh`。

首次在新机器上开发前运行一次 `./scripts/setup-dev-cert.sh`：它创建名为 `Amai Local Dev` 的自签名代码签名证书，`bundle.sh` 检测到后自动使用。没有它时打包是 ad-hoc 签名，macOS TCC 按代码哈希记权限，每次重新打包都要重新授权屏幕录制。

首次点击菜单栏的"开始采集"后，macOS 会请求屏幕录制权限（系统设置 → 隐私与安全性 → 屏幕录制），允许一次即可。

运行时数据：`~/Library/Application Support/Amai/`（`config.json` 可手改；`raw/` 为短期缓冲，截图帧存为按日目录下的 HEVC 分段，默认 72 小时 / 2 GB 上限）。

## 包结构

```text
Sources/
├── AmaiCore/         数据契约（PerceptionEvent、Observation、ActivitySegment、MemoryEntry）、时钟、日志约定
├── AmaiPerception/   屏幕 / 音频 / 键鼠采集、权限、原始缓冲、隐私策略
├── AmaiExtraction/   OCR、ModelProvider（mlx-swift-lm）、时间窗口聚合、活动识别
├── AmaiMemory/       Markdown 存储、写入规则、派生索引（GRDB）、检索
└── Amai/             菜单栏应用
Tests/                每个 target 一个测试 target
scripts/              bundle.sh、build-mlx-metallib.sh
```

当前阶段：M0 项目启动（技术栈已确认，见 [ADR-0002](docs/decisions/0002-tech-stack.md)）。
