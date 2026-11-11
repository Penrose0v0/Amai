# Amai — Ambient Personal AI

在 macOS 上后台感知用户活动，抽取语义上下文，沉淀为用户可读、可编辑的 Markdown 长期记忆。

- 工程约束与 Agent 工作规范：[AGENTS.md](AGENTS.md)
- 产品定义：[docs/product.md](docs/product.md)
- 架构：[docs/architecture.md](docs/architecture.md)
- 记忆系统：[docs/memory.md](docs/memory.md)
- 路线图：[docs/roadmap.md](docs/roadmap.md)
- 决策记录：[docs/decisions/](docs/decisions/)
- 发布与安装：[docs/release.md](docs/release.md)
- 参考研究：[docs/references/](docs/references/)

## 安装

```bash
brew install --cask Penrose0v0/tap/amai
```

要求 Apple Silicon、macOS 15+。发布流程见 [docs/release.md](docs/release.md)。

## 开发

要求：macOS 15+、Xcode 26（含 Metal 工具链组件）、Swift 6.x。

```bash
swift build                  # 编译
swift test                   # 运行不依赖 MLX 权重的测试
./scripts/bundle.sh          # 组装 .build/Amai.app（含 mlx.metallib、签名）
open .build/Amai.app         # 运行（菜单栏应用）
```

直接 `swift run` 无法运行涉及 MLX 推理的代码路径（SwiftPM 不编译 Metal kernel），必须通过 `bundle.sh`。

代码签名：`bundle.sh` 优先使用本机的 "Apple Development" 证书（在 Xcode 中登录 Apple ID 即可获得，免费账号也可）。带团队 ID 的签名让屏幕录制授权和钥匙串授权在重新打包后保持有效。没有这类证书时退回 `./scripts/setup-dev-cert.sh` 创建的自签名证书 `Amai Local Dev`，此时每次重新打包后，钥匙串会再次弹出授权框（"始终允许"只对当次构建有效）。也可以用环境变量 `AMAI_SIGN_IDENTITY` 指定签名身份。

首次点击菜单栏的"开始记录"后，macOS 会请求屏幕录制权限（系统设置 → 隐私与安全性 → 屏幕录制），允许一次即可。

记忆：`~/.amai/memory/`（可在 `config.json` 的 `memory.root` 修改）。`daily/YYYY-MM-DD.md` 中两条 `amai:timeline` 注释之间由系统维护，区块外可以随意编辑。开发时检索记忆：`swift run amai-memory search <查询>`。记忆整理默认用本地模型；可在"设置… → 记忆整理"中切换到 Anthropic / OpenAI 的 API Key（ADR-0004），或使用 ChatGPT 订阅（官方 Sign in with ChatGPT）、Claude 订阅（本机已登录的 Claude Code）（ADR-0005）。立即整理（开发用）：`open .build/Amai.app --args --consolidate-today --update-summary`。

运行时数据：`~/Library/Application Support/Amai/`（`config.json` 可手改；`raw/` 为短期缓冲，截图帧存为按日目录下的 HEVC 分段，默认 72 小时 / 2 GB 上限）。

## 包结构

```text
Sources/
├── AmaiCore/         数据契约（PerceptionEvent、Observation、ActivitySegment、MemoryEntry）、时钟、日志约定
├── AmaiPerception/   屏幕 / 音频 / 键鼠采集、权限、原始缓冲、隐私策略
├── AmaiExtraction/   OCR、ModelProvider（mlx-swift-lm）、时间窗口聚合、活动识别
├── AmaiMemory/       Markdown 存储、写入规则、派生索引（GRDB）、检索
├── AmaiMemoryCLI/    开发用记忆检索命令行 amai-memory
└── Amai/             菜单栏应用、检查器，以及各层之间的装配
Tests/                每个 target 一个测试 target
scripts/              bundle.sh、build-mlx-metallib.sh、release.sh、verify-bundle.sh、set-version.sh
packaging/homebrew/   Homebrew cask 模板
```

当前阶段：M0 项目启动（技术栈已确认，见 [ADR-0002](docs/decisions/0002-tech-stack.md)）。
