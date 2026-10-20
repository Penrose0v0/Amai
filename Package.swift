// swift-tools-version: 6.0
import PackageDescription

// 依赖方向在包层面强制：
//   AmaiCore ← AmaiPerception / AmaiExtraction / AmaiMemory ← Amai（App）
// 三个层 target 互不依赖，只依赖 AmaiCore 的数据契约。见 docs/architecture.md §8。
let package = Package(
    name: "Amai",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Amai", targets: ["Amai"]),
        .executable(name: "amai-memory", targets: ["AmaiMemoryCLI"]),
    ],
    dependencies: [
        // 记忆层派生索引（SQLite + FTS5）。ADR-0002。
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),

        // 嵌入式本地推理（ADR-0002）。沿用 Eira 项目的 fork 与 pin：
        // upstream main + 三处 Gemma 4 视觉修复（pooler kernel 截断、保持宽高比缩放、
        // 多图打包），这些修复尚未进入上游 tag。上游合入后切回 ml-explore/mlx-swift-lm。
        // 注意：SwiftPM 不编译 .metal，运行时需要 scripts/build-mlx-metallib.sh 产出的
        // mlx.metallib（由 scripts/bundle.sh 调用）。
        .package(url: "https://github.com/Penrose0v0/mlx-swift-lm", revision: "6d73582ad31f9a7ee42f879d3570d96fe5a1a347"),
        // mlx-swift 是 mlx-swift-lm 的传递依赖；直接列出以便 `import MLX`
        // 使用 GPU 内存管理 API（cacheLimit、clearCache、内存压力处理）。
        .package(url: "https://github.com/ml-explore/mlx-swift", from: "0.31.3"),
        .package(url: "https://github.com/huggingface/swift-huggingface", from: "0.9.0"),
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.3.0"),
    ],
    targets: [
        // 数据契约、时钟、日志约定。无平台依赖、无第三方依赖。
        .target(name: "AmaiCore"),

        // 感知层：屏幕 / 音频 / 键鼠采集、权限、原始缓冲、隐私策略。
        .target(
            name: "AmaiPerception",
            dependencies: ["AmaiCore"]
        ),

        // 抽取层：OCR、模型 Provider、时间窗口聚合、活动识别。
        .target(
            name: "AmaiExtraction",
            dependencies: [
                "AmaiCore",
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXVLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
                .product(name: "HuggingFace", package: "swift-huggingface"),
                .product(name: "Tokenizers", package: "swift-transformers"),
            ]
        ),

        // 记忆层：Markdown 存储、写入规则、派生索引、检索。
        .target(
            name: "AmaiMemory",
            dependencies: [
                "AmaiCore",
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),

        // 菜单栏应用。只通过各层公开接口工作，不含业务逻辑。
        .executableTarget(
            name: "Amai",
            dependencies: ["AmaiCore", "AmaiPerception", "AmaiExtraction", "AmaiMemory"]
        ),

        // 开发用记忆检索命令行：swift run amai-memory search <查询>
        .executableTarget(
            name: "AmaiMemoryCLI",
            dependencies: ["AmaiMemory"]
        ),

        .testTarget(name: "AmaiCoreTests", dependencies: ["AmaiCore"]),
        .testTarget(name: "AmaiPerceptionTests", dependencies: ["AmaiPerception"]),
        .testTarget(name: "AmaiExtractionTests", dependencies: ["AmaiExtraction"]),
        .testTarget(name: "AmaiMemoryTests", dependencies: ["AmaiMemory"]),
    ]
)
