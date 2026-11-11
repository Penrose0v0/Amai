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

## 签名与公证

- 签名身份与开发构建相同（`bundle.sh`：`AMAI_SIGN_IDENTITY` → Apple Development → 自签名 → ad-hoc）。签名身份保持不变，用户升级后屏幕录制授权与钥匙串授权才能继续有效。
- 签名信息（证书名称、团队 ID）会随 App 分发，任何人都可以用 `codesign -dvv` 看到。
- 目前**没有公证**：Gatekeeper 会拦截带隔离属性的 App。cask 在安装后用 `postflight_steps` 去掉隔离属性；手动下载 zip 的用户需要执行 `xattr -dr com.apple.quarantine /Applications/Amai.app`。

## 卸载时保留的数据

- `brew uninstall` 只删除 App；cask 的 `uninstall quit` 会先退出 Amai，让录制正常收尾。
- `brew uninstall --zap` 另外删除 `~/Library/Application Support/Amai`（配置、原始缓冲、索引）与偏好设置。
- 记忆目录（默认 `~/.amai/memory`）是用户自己的笔记，任何卸载方式都**不会删除**。
- 下载的本地模型在 Hugging Face 缓存中，与其他应用共用，也不会删除。
