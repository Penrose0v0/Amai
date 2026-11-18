// swift-tools-version: 6.0
import PackageDescription

// 依赖方向在包层面强制：
//   AmaiCore ← AmaiPerception / AmaiExtraction / AmaiMemory ← Amai（App）
// 三个层 target 互不依赖，只依赖 AmaiCore 的数据契约。见 docs/architecture.md §8。
// 模型运行时 AmaiInference 只依赖 AmaiCore，被抽取层与 App 使用。
let package = Package(
    name: "Amai",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Amai", targets: ["Amai"]),
        .executable(name: "amai-memory", targets: ["AmaiMemoryCLI"]),
        .executable(name: "amai-extraction", targets: ["AmaiExtractionCLI"]),
        .executable(name: "amai-mcp", targets: ["AmaiMCPServer"]),
    ],
    dependencies: [
        // 记忆层派生索引（SQLite + FTS5）。ADR-0002。
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),

        // 嵌入式本地推理（ADR-0002）。3.32.3 已包含此前 fork 中的 Gemma 4 视觉修复
        // （pooler kernel、保持宽高比缩放、多图逐张编码），以及 E 系列 KV 共享层的 VLM 加载（PR #384）。
        // 锁定确切版本：升级后需重新运行推理检查（docs/release.md）。
        // 注意：SwiftPM 不编译 .metal，运行时需要 scripts/build-mlx-metallib.sh 产出的
        // mlx.metallib（由 scripts/bundle.sh 调用）。
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", exact: "3.32.3"),
        // mlx-swift 是 mlx-swift-lm 的传递依赖；直接列出以便 `import MLX`
        // 使用 GPU 内存管理 API（cacheLimit、clearCache、内存压力处理）。
        .package(url: "https://github.com/ml-explore/mlx-swift", from: "0.32.3"),
        .package(url: "https://github.com/huggingface/swift-huggingface", from: "0.9.0"),
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.3.0"),
        // 只读 MCP Server 的协议实现（官方 Swift SDK，ADR-0008）。只有 AmaiMCP 依赖它，App 不链接。
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk", exact: "0.12.1"),
    ],
    targets: [
        // 数据契约、时钟、日志约定。无平台依赖、无第三方依赖。
        .target(name: "AmaiCore"),

        // 感知层：屏幕 / 音频 / 键鼠采集、权限、原始缓冲、隐私策略。
        .target(
            name: "AmaiPerception",
            dependencies: ["AmaiCore"]
        ),

        // 模型运行时：本地 MLX 模型的加载、共享与调度（交互式优先于后台），单次调用与对话两种入口。
        // 抽取、记忆整理、Agent 都经由它使用本地模型；同一个模型标签在进程内只加载一份权重。
        .target(
            name: "AmaiInference",
            dependencies: [
                "AmaiCore",
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXVLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXEmbedders", package: "mlx-swift-lm"),
                .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
                .product(name: "HuggingFace", package: "swift-huggingface"),
                .product(name: "Tokenizers", package: "swift-transformers"),
            ]
        ),

        // 抽取层：时间窗口聚合、观察抽取、活动识别。模型经 AmaiInference 的 ModelProvider 调用。
        .target(
            name: "AmaiExtraction",
            dependencies: ["AmaiCore", "AmaiInference"]
        ),

        // 记忆层：Markdown 存储、写入规则、派生索引、检索。
        .target(
            name: "AmaiMemory",
            dependencies: [
                "AmaiCore",
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),

        // 记忆整理评测：用合成场景测量路由召回、准确率、遗漏、错误归属、跨天矛盾与过时处理。
        // 只在开发时由 App 的 --memory-eval 启动参数调用，不参与正常运行。
        .target(
            name: "AmaiMemoryEval",
            dependencies: ["AmaiCore", "AmaiMemory"]
        ),

        // 记忆窗口的 SwiftUI 视图（只读浏览、检索、来源查看）。通过回调与 App 交互，便于在测试中渲染检查。
        .target(
            name: "AmaiMemoryUI",
            dependencies: ["AmaiCore", "AmaiMemory"]
        ),

        // 云端文本模型客户端（Anthropic / OpenAI）与钥匙串。只用于记忆整理（ADR-0004）。
        // 只依赖 AmaiCore 的对话契约（ChatModel），不依赖任何层；由 App 适配到记忆层的 MemoryLanguageModel。
        .target(name: "AmaiCloud", dependencies: ["AmaiCore"]),

        // 内置助手的逻辑（不含界面）：Agent 循环、每轮上下文的组装、记忆与屏幕工具、会话存储、快速文本操作。
        // 只面向 AmaiCore 的契约（ChatModel、LiveContextReading）与记忆层的只读 MemoryAPI；
        // 不依赖感知层、抽取层和具体的模型实现，这些由 App 装配。
        .target(
            name: "AmaiAssistant",
            dependencies: ["AmaiCore", "AmaiMemory", .product(name: "GRDB", package: "GRDB.swift")]
        ),

        // 菜单栏应用。只通过各层公开接口工作，不含业务逻辑。
        .executableTarget(
            name: "Amai",
            dependencies: [
                "AmaiCore", "AmaiPerception", "AmaiInference", "AmaiExtraction", "AmaiMemory", "AmaiMemoryEval",
                "AmaiMemoryUI", "AmaiCloud", "AmaiAssistant",
            ]
        ),

        // 开发用记忆检索命令行：swift run amai-memory search <查询>；eval 子命令用 Claude Code 或本地模型跑记忆整理评测。
        .executableTarget(
            name: "AmaiMemoryCLI",
            dependencies: ["AmaiMemory", "AmaiMemoryEval", "AmaiCloud", "AmaiExtraction"]
        ),

        // 开发用抽取评测命令行：amai-extraction eval，在已录制的原始帧上用指定本地模型重跑抽取，比较速度、内存与切分。
        // 只读原始缓冲，结果写到独立的输出目录。
        .executableTarget(
            name: "AmaiExtractionCLI",
            dependencies: ["AmaiCore", "AmaiPerception", "AmaiExtraction"]
        ),

        // 只读 MCP Server（ADR-0008）：把 MemoryAPI 暴露为 MCP Tools。MCP 只是外部接口，
        // App 内部（今后的 Eira Assistant）直接调用 AmaiMemory 的 MemoryAPI。
        .target(
            name: "AmaiMCP",
            dependencies: ["AmaiCore", "AmaiMemory", .product(name: "MCP", package: "swift-sdk")]
        ),

        // amai-mcp：由外部 Agent（Claude Desktop、Atd 等）以 stdio 启动。随 App 打包在 Contents/MacOS。
        .executableTarget(
            name: "AmaiMCPServer",
            dependencies: ["AmaiMCP"]
        ),

        .testTarget(name: "AmaiCoreTests", dependencies: ["AmaiCore"]),
        .testTarget(name: "AmaiPerceptionTests", dependencies: ["AmaiPerception"]),
        .testTarget(name: "AmaiExtractionTests", dependencies: ["AmaiExtraction"]),
        .testTarget(name: "AmaiInferenceTests", dependencies: ["AmaiMemory", "AmaiInference"]),
        .testTarget(name: "AmaiAssistantTests", dependencies: ["AmaiAssistant", "AmaiMemory"]),
        .testTarget(name: "AmaiMemoryTests", dependencies: ["AmaiMemory", "AmaiMemoryEval", "AmaiMemoryUI"]),
        .testTarget(name: "AmaiCloudTests", dependencies: ["AmaiCloud"]),
        .testTarget(name: "AmaiMCPTests", dependencies: ["AmaiMCP", "AmaiMemory", .product(name: "MCP", package: "swift-sdk")]),
    ]
)
