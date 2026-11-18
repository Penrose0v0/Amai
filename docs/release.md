# 发布与安装分发

Amai 通过 GitHub Releases 分发预构建的 `Amai.app`，用户用 Homebrew Cask 安装（与 Eira 相同的流程）。

```bash
brew install --cask Penrose0v0/tap/amai     # 安装
brew upgrade --cask amai                    # 更新
brew uninstall --cask amai                  # 卸载（记忆文件保留）
```

要求：Apple Silicon、macOS 15+。

## 组成

| 位置 | 内容 |
|---|---|
| `Penrose0v0/Amai` 的 GitHub Releases | `Amai-X.Y.Z.zip`（仓库公开，brew 可直接下载；Eira 仓库为私有，所以 Eira 的 zip 放在 tap 仓库） |
| `Penrose0v0/homebrew-tap` 的 `Casks/amai.rb` | cask，与 Eira 共用同一个 tap |
| `packaging/homebrew/amai.rb.template` | cask 模板；`release.sh` 填入版本与 sha256 |
| `scripts/release.sh` | Release 构建、检查、打包、生成 cask 与发布说明，打印发布命令；**不发布** |
| `scripts/verify-bundle.sh` | 检查 App 是否完整可分发 |
| `scripts/set-version.sh` | 设置版本号 |

## 发布一个版本

1. 设置版本号（唯一来源是 `Resources/Info.plist`；`amai-mcp` 从 App 的 Info.plist 读取同一版本）：

   ```bash
   ./scripts/set-version.sh 0.2.0     # 版本号设为 0.2.0，构建号加 1
   git commit -am "chore: release v0.2.0"
   ```

2. 构建并打包（要求工作区干净；本地试打包可加 `--allow-dirty`）：

   ```bash
   ./scripts/release.sh
   ```

   - App 组装在 `.build/dist/Amai.app`，不退出、不替换正在运行的开发版，不读写用户数据。
   - 依次执行 `bundle.sh release`（MLX metallib、`amai-mcp`、界面翻译、SwiftPM 资源 bundle、Swift 运行库、签名）→ `verify-bundle.sh` → `ditto` 打包。
   - 产出 `dist/Amai-X.Y.Z.zip`、`dist/amai.rb`、`dist/RELEASE_NOTES-X.Y.Z.md`（`dist/` 不提交）。

3. 按脚本最后打印的命令发布：推送 tag → `gh release create` 上传 zip → 把 `dist/amai.rb` 复制到 tap 仓库的 `Casks/amai.rb` 并推送。

## verify-bundle.sh 检查的内容

- 版本号与预期一致；`Amai`、`amai-mcp` 为 arm64；
- `mlx.metallib` 在可执行文件旁边（MLX 在那里查找）；
- `zh-Hans` / `en` / `ja` 的界面翻译与权限说明；SwiftPM 资源 bundle 都有 Info.plist；
- 动态库只链接系统库与 `Contents/Frameworks`，rpath 不含 Xcode 或 `/Users/` 路径；
- 代码签名完整有效（`codesign --verify --strict --deep`）；
- `amai-mcp` 能完成 MCP 握手、列出三个工具、版本号与 App 一致，默认关闭（使用临时配置，不读取任何记忆）。

## 发布前的推理检查

`verify-bundle.sh` 不加载模型。每次升级 mlx-swift-lm / mlx-swift 或发布前，用组装好的 App 在隔离预览模式下检查本地推理：

```bash
DIR=$(mktemp -d); mkdir -p "$DIR/memory"
.build/dist/Amai.app/Contents/MacOS/Amai --memory-preview "$DIR" \
    --inference-check <输出目录> --inference-model mlx-community/gemma-4-e4b-it-4bit
cat <输出目录>/inference.json
```

- 在本进程中加载模型（只读 Hugging Face 缓存中的权重），依次做纯文本生成与三项视觉对照：读出合成图片上的文字、说出纯色图片的颜色、同一问题不带图时答不出图中文字。`ok` 为 true 才说明图片真正进入了模型。
- 预览模式不读写真实记忆、配置与原始数据，不启动采集，不影响正在运行的 Amai。
- 加 `--inference-download` 时，未安装的模型先用设置中的同一个下载器下载。

### 助手检查（2026-11-18）

与推理检查同一类：隔离预览模式下用合成记忆和本地模型走一遍助手的真实装配路径，不影响正在运行的 Amai。

```bash
DIR=$(mktemp -d); mkdir -p "$DIR/memory" "$DIR/support/extracted"
cp -R samples/memory-preview/. "$DIR/memory/"
.build/dist/Amai.app/Contents/MacOS/Amai --memory-preview "$DIR" \
    --assistant-check <输出目录> [--assistant-model <模型标签>]
cat <输出目录>/assistant.json
```

- 依次检查：交互式屏幕读取（焦点、显示器与前台窗口截图、OCR；只记录尺寸与耗时）、记忆的向量索引、记忆问答（后端检索并带来源，全程没有工具调用）、追问（"那天"的指代、KV cache 复用）、措辞不同的问题能否靠语义检索答对、翻译与润色、快速操作之后对话缓存是否仍在。`ok` 为 true 表示全部通过。
- 同一个问题问两次并记录各阶段耗时：`coldSubmit` 是不做任何准备直接提交；`conversation[0]` 是先按面板唤出时的流程准备（`prepare`）再提交。`preparedIsFaster`、`prefillHit`、`preparedContextUsed` 三项确认预填充确实被用上。
- 语义检索模型没有下载时 `semanticRecall` 会失败（`memory.embedderInstalled` 为 false）；它是可选的，这种情况下只说明走的是关键词检索。
- 同时截下聊天面板（`chat.png`）与快速操作面板（`quick.png`），只截本应用自己的窗口。
- 屏幕读取需要屏幕录制权限；窗口标题需要辅助功能权限，没有时相应字段为 false，不算失败。
- 本地模型的集成测试：把 `mlx.metallib` 复制到 xctest 可执行文件旁，运行 `AMAI_MLX_INTEGRATION=1 swift test --filter "MLXIntegrationTests|EmbedderIntegration|RetrievalEval"`。分别验证对话的缓存复用与预填充、向量模型、以及合成记忆库上的检索质量（关键词与混合检索的对比）。

## 应用内更新（2026-11-18）

参考 Eira：`UpdateController`（App）与 `AppUpdate`（AmaiCore，纯逻辑与测试）。

- 启动 15 秒后检查一次 `https://api.github.com/repos/Penrose0v0/Amai/releases/latest`，之后每 6 小时一次；只读取公开的版本号，不发送用户数据，失败时静默跳过。草稿与预发布不算新版本。隔离预览模式不联网检查。
- 有新版本：菜单栏图标换成蓝色（非模板的调色板符号），菜单最上方出现「更新到 vX」。
- Homebrew 安装的副本（在「应用程序」文件夹，且 Caskroom 中有 amai）：确认后像退出一样收尾（视频分段正常结束），由独立的 `/bin/sh` 运行 `brew upgrade --cask amai`，输出写入日志文件，结束后无论成败都重新打开 App。不能在 Amai 进程内等待：cask 的 `uninstall quit` 会在升级时退出 Amai。
- 重新打开后读取升级记录（`$TMPDIR/amai-update/`）：退出码为 0 且版本确实变新才算成功；否则菜单中显示「更新到 vX 失败」与 brew 输出的最后几行，并提供「打开下载页面」。「更新到 vX」按钮同时就是重试。
- 其他副本（开发构建 `.build/Amai.app`、手动下载）不能原地升级，点击后打开下载页面。
- 在预览中查看效果：`--memory-preview <目录> --preview-update 0.2.0`；`--menubar-tour <输出目录>` 截取菜单栏图标。

## 签名与公证

- 签名身份与开发构建相同（`bundle.sh`：`AMAI_SIGN_IDENTITY` → Apple Development → 自签名 → ad-hoc）。签名身份保持不变，用户升级后屏幕录制授权与钥匙串授权才能继续有效。
- 签名信息（证书名称、团队 ID）会随 App 分发，任何人都可以用 `codesign -dvv` 看到。
- 目前**没有公证**：Gatekeeper 会拦截带隔离属性的 App。cask 在安装后用 `postflight_steps` 去掉隔离属性；手动下载 zip 的用户需要执行 `xattr -dr com.apple.quarantine /Applications/Amai.app`。

## 卸载时保留的数据

- `brew uninstall` 只删除 App；cask 的 `uninstall quit` 会先退出 Amai，让录制正常收尾。
- `brew uninstall --zap` 另外删除 `~/Library/Application Support/Amai`（配置、原始缓冲、索引）与偏好设置。
- 记忆目录（默认 `~/.amai/memory`）是用户自己的笔记，任何卸载方式都**不会删除**。
- 下载的本地模型在 Hugging Face 缓存中，与其他应用共用，也不会删除。
