import CryptoKit
import Foundation

/// 检索用的分词（docs/memory.md §6）。索引与查询必须用同一套规则，所以放在一处。
///
/// - 拉丁字母与数字：按词切分并转小写；
/// - 汉字：相邻两字一组（bigram）。中文没有空格，常用词多为两个字，bigram 能精确匹配两字词，
///   更长的词由相邻的 bigram 共同命中；单独一个汉字时保留单字；
/// - 片假名：整段作为一个词；平假名：两字一组（多为助词与活用词尾，查询时丢弃）。
///
/// 这是 Lucene CJKAnalyzer 与 OpenClaw 查询扩展（Han bigram）采用的做法，不依赖系统分词器，结果确定、可测试。
enum MemoryTerms {
    private enum Script {
        case word
        case han
        case hiragana
        case katakana
        case separator
    }

    private static func script(_ scalar: Unicode.Scalar) -> Script {
        switch scalar.value {
        case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x2A6DF: return .han
        case 0x3041...0x3096, 0x309D...0x309F: return .hiragana
        // 长音符号属于片假名词的一部分。
        case 0x30A1...0x30FA, 0x30FC...0x30FF, 0x31F0...0x31FF: return .katakana
        default:
            if scalar == "_" { return .word }
            return scalar.properties.isAlphabetic || scalar.properties.numericType != nil ? .word : .separator
        }
    }

    private static func normalize(_ text: String) -> String {
        // NFKC：全角字母数字变半角、半角片假名变全角，写法不同的同一个词归到一起。
        // 再做一次 NFC：半角浊音符展开后要与前面的假名重新合成一个字。
        text.precomposedStringWithCompatibilityMapping.precomposedStringWithCanonicalMapping.lowercased()
    }

    /// 同一种文字的连续片段。
    private static func runs(_ text: String) -> [(Script, String)] {
        var result: [(Script, String)] = []
        var current = String.UnicodeScalarView()
        var kind = Script.separator
        func flush() {
            if kind != .separator, !current.isEmpty { result.append((kind, String(current))) }
            current = String.UnicodeScalarView()
        }
        for scalar in normalize(text).unicodeScalars {
            let next = script(scalar)
            if next != kind {
                flush()
                kind = next
            }
            if next != .separator { current.append(scalar) }
        }
        flush()
        return result
    }

    private static func bigrams(_ run: String) -> [String] {
        let characters = Array(run)
        guard characters.count > 1 else { return [run] }
        return (0..<characters.count - 1).map { String(characters[$0...$0 + 1]) }
    }

    /// 写入索引的词（保留重复，词频参与 BM25）。
    static func indexTerms(_ text: String) -> [String] {
        runs(text).flatMap { kind, run -> [String] in
            switch kind {
            case .word, .katakana: [run]
            case .han, .hiragana: bigrams(run)
            case .separator: []
            }
        }
    }

    /// 从问题里取出用于检索的词：去掉疑问词、助词等对检索没有区分度的部分，去重并保持顺序。
    static func queryTerms(_ text: String) -> [String] {
        var terms: [String] = []
        for (kind, run) in runs(text) {
            switch kind {
            case .word:
                // 单个字母、一两位的数字几乎出现在每一段里。
                let isNumber = run.unicodeScalars.allSatisfy { $0.properties.numericType != nil }
                if run.count < 2 || (isNumber && run.count < 3) || latinStopWords.contains(run) { continue }
                terms.append(run)
            case .katakana:
                terms.append(run)
            case .han:
                for piece in splitAtStopWords(run) { terms += bigrams(piece) }
            case .hiragana, .separator:
                continue
            }
        }
        var seen = Set<String>()
        return terms.filter { seen.insert($0).inserted }
    }

    /// 在停用词处把一段汉字切开，停用词本身丢弃。单个汉字的碎片（"我""在"之间剩下的字）一并丢弃：
    /// 单字在索引里只对应孤立的单字，几乎不会命中有意义的内容。
    private static func splitAtStopWords(_ run: String) -> [String] {
        var pieces: [String] = []
        var current = ""
        var rest = Substring(run)
        outer: while !rest.isEmpty {
            for stop in hanStopWords where rest.hasPrefix(stop) {
                if current.count > 1 { pieces.append(current) }
                current = ""
                rest = rest.dropFirst(stop.count)
                continue outer
            }
            current.append(rest.removeFirst())
        }
        if current.count > 1 { pieces.append(current) }
        // 整段都是停用词或单字时（例如只问了"钱"），保留原样，不让查询变空。
        return pieces.isEmpty && run.count <= 2 ? [run] : pieces
    }

    /// 长的在前：先匹配"为什么"再匹配"什么"。
    private static let hanStopWords: [String] = [
        "为什么", "有没有", "是不是", "能不能", "什么", "怎么", "怎样", "如何", "多少", "哪些", "哪个", "哪里",
        "是否", "一下", "一个", "一些", "时候", "关于", "告诉", "可以", "我们", "你们", "他们", "这个", "那个",
        "这些", "那些", "主要", "的", "了", "吗", "呢", "吧", "啊", "呀", "是", "在", "我", "你", "他", "她",
        "它", "有", "和", "与", "及", "或", "也", "都", "就", "还", "很", "把", "被", "给", "对", "从", "到",
        "向", "这", "那", "哪", "谁", "几", "过", "着", "要", "会", "能", "请", "帮", "做", "没", "不",
    ].sorted { $0.count > $1.count }

    private static let latinStopWords: Set<String> = [
        "the", "an", "and", "or", "of", "to", "in", "on", "at", "for", "with", "by", "from", "about", "as",
        "is", "are", "was", "were", "be", "been", "am", "do", "does", "did", "have", "has", "had", "it", "its",
        "this", "that", "these", "those", "my", "me", "we", "you", "your", "he", "she", "they", "them",
        "what", "when", "where", "which", "who", "whom", "why", "how", "can", "could", "would", "should",
        "will", "any", "some", "there", "not", "no", "so", "if", "than", "then", "tell", "please", "much", "many",
    ]

    /// 两段文字的相似度（词集合的 Jaccard），用于结果去重。
    static func jaccard(_ a: Set<String>, _ b: Set<String>) -> Double {
        if a.isEmpty && b.isEmpty { return 1 }
        let union = a.union(b).count
        return union == 0 ? 0 : Double(a.intersection(b).count) / Double(union)
    }
}

/// 把一个 section 切成检索用的小块。
///
/// 记忆文件里的内容本来就是一条一条的（长期记忆的条目、时间线的片段），所以按条目切、不做重叠：
/// 以 `- ` 开头的行开始一个新条目，后面不以 `- ` 开头的行（摘要、续行）跟着它；相邻的条目合并到接近上限为止。
/// section 内的小节标题（`### 项目名`）另起一块并成为这一块的标题，不同项目的条目不会混在一起。
/// 块小，命中更准，放进提示词的内容也更少。
enum MemoryChunker {
    struct Chunk: Equatable {
        let heading: String
        let content: String
        let position: Int
    }

    /// 一块的大小上限，按估算的 token 数（汉字每字 1，其余每 4 个字符 1）。
    /// 取 240：既装得下几条相关的条目，又留在小型向量模型 512 token 的输入上限之内。
    static let maxTokens = 240

    static func estimatedTokens(_ text: String) -> Int {
        var wide = 0
        var narrow = 0
        for scalar in text.unicodeScalars {
            if scalar.value >= 0x2E80 { wide += 1 } else { narrow += 1 }
        }
        return wide + (narrow + 3) / 4
    }

    static func chunks(heading: String, content: String, startingAt position: Int) -> [Chunk] {
        var chunks: [Chunk] = []
        var subheading = heading
        var current: [String] = []
        var size = 0
        func flush() {
            guard !current.isEmpty else { return }
            chunks.append(Chunk(heading: subheading, content: current.joined(separator: "\n"), position: position + chunks.count))
            current = []
            size = 0
        }
        func add(_ entry: String) {
            for part in split(entry) {
                let tokens = estimatedTokens(part)
                if size + tokens > maxTokens { flush() }
                current.append(part)
                size += tokens
            }
        }
        var entry: String?
        var isBullet = false
        for line in content.split(separator: "\n") {
            if line.hasPrefix("#") {
                // 小节标题（长期记忆里的项目名、专题名）：另起一块，并作为这一块的标题。
                if let entry { add(entry) }
                entry = nil
                isBullet = false
                flush()
                let name = line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
                subheading = name.isEmpty ? heading : name
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                // 每个条目单独成块：一块只讲一件事，向量不被同一天里的其他活动稀释，放进提示词的也只是相关的那一条。
                if let entry { add(entry) }
                flush()
                entry = String(line)
                isBullet = true
            } else if entry == nil || (isBullet && line.isEmpty) {
                if let entry { add(entry) }
                entry = String(line)
                isBullet = false
            } else {
                entry = (entry ?? "") + "\n" + line
            }
        }
        if let entry { add(entry) }
        flush()
        return chunks
    }

    /// 单个条目超过上限时按字符硬切（极少见：一整段没有换行的长文）。
    private static func split(_ entry: String) -> [String] {
        guard estimatedTokens(entry) > maxTokens else { return [entry] }
        var parts: [String] = []
        var current = ""
        var size = 0
        for character in entry {
            let tokens = estimatedTokens(String(character))
            if size + tokens > maxTokens, !current.isEmpty {
                parts.append(current)
                current = ""
                size = 0
            }
            current.append(character)
            size += tokens
        }
        if !current.isEmpty { parts.append(current) }
        return parts
    }

    /// 送去计算向量的文字：标题加正文。它的哈希是向量缓存的键，内容没变就不重算。
    static func embeddingText(heading: String, content: String) -> String {
        heading.isEmpty ? content : heading + "\n" + content
    }

    static func hash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }
}
