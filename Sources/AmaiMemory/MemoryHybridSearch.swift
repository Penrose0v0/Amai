import Accelerate
import AmaiCore
import Foundation
import GRDB

/// 混合检索的一条结果：一个小块，带各路得分。
public struct MemoryChunkHit: Sendable, Equatable {
    public let id: Int64
    public let file: String
    public let category: MemoryCategory?
    public let heading: String
    public let content: String
    /// daily 文件对应的日期（当天 00:00）；长期记忆为 nil。
    public let day: Date?
    /// 融合后的相关度（0…1），不含时间衰减。
    public let score: Double
    /// 语义相似度（按这次查询在整个索引上的分布校准到 0…1）；没有向量时为 nil。
    public let vectorScore: Double?
    /// 关键词得分（0…1）；关键词没有命中时为 nil。
    public let keywordScore: Double?
}

/// 混合检索的参数。默认值取自 OpenClaw 的 memory search（`src/agents/memory-search.ts`）：
/// 向量 0.7 / 关键词 0.3 加权求和、每路取 4 倍候选、最多 6 条、MMR λ=0.7、时间衰减半衰期 30 天。
/// 最低分 OpenClaw 用 0.35；这里是 0.30：在合成记忆库的评测里，几个只靠语义命中的正确结果落在 0.32–0.34。
public struct MemorySearchOptions: Sendable, Equatable {
    public var maxResults = 6
    public var minScore = 0.30
    public var vectorWeight = 0.7
    public var textWeight = 0.3
    public var candidateMultiplier = 4
    public var mmrLambda = 0.7
    public var halfLifeDays = 30.0
    /// 时间衰减的下限。OpenClaw 没有下限（旧内容可以衰减到接近 0）；个人记忆里几个月前的事
    /// 仍然是用户会问的内容，所以只让新旧影响排序，不让旧内容彻底沉底。
    public var decayFloor = 0.6
    /// 向量命中至少要比索引的平均相似度高出多少个标准差（见 `calibrate`）。
    public var vectorMinZ = 1.5
    public var categories: Set<MemoryCategory>?
    public var dayRange: ClosedRange<Date>?
    /// 等待问题向量的最长时间：超过就只用关键词（向量模型可能正在加载，或在给后台任务让路）。
    public var embeddingTimeout: TimeInterval = 2
    public var now = Date()

    public init() {}
}

extension MemoryIndex {
    public struct EmbeddingStatus: Sendable, Equatable {
        public var chunks = 0
        public var embedded = 0
    }

    /// 关键词（BM25）与向量两路检索，加权融合，再做时间衰减与去重（MMR）。
    ///
    /// - 没有向量模型、模型不可用、问题向量超时或索引里还没有向量时，只用关键词；
    /// - 关键词一条都没命中而向量可用时，只用向量。
    public func search(
        _ query: String, embedder: (any TextEmbedder)? = nil, options: MemorySearchOptions = MemorySearchOptions()
    ) async throws -> [MemoryChunkHit] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, options.maxResults > 0 else { return [] }
        let candidates = max(24, options.maxResults * options.candidateMultiplier)

        let terms = MemoryTerms.queryTerms(q)
        var merged: [Int64: Candidate] = [:]
        for hit in try keywordCandidates(terms: terms, options: options, limit: candidates) {
            merged[hit.row.id] = hit
        }

        var vectorUsed = false
        if let embedder, embedder.isAvailable,
           let vector = await Self.queryVector(q, embedder: embedder, timeout: options.embeddingTimeout) {
            let (hits, similarities) = try vectorCandidates(vector, embedder: embedder, options: options, limit: candidates)
            vectorUsed = !hits.isEmpty
            for (row, similarity) in hits {
                if merged[row.id] != nil {
                    merged[row.id]?.vector = similarity
                } else {
                    merged[row.id] = Candidate(row: row, keyword: nil, vector: similarity)
                }
            }
            // 关键词命中、却没进向量候选的块：补上它真实的语义得分，而不是当作 0。
            // 否则它的融合得分最多只有 textWeight（0.3），过不了最低分，关键词命中得再好也会被丢掉
            // （真实记忆评测里有 5 个信息点纯关键词能找到、混合检索前 50 名却没有）。
            if vectorUsed {
                for id in merged.keys where merged[id]?.vector == nil {
                    merged[id]?.vector = similarities[id]
                }
            }
        }
        guard !merged.isEmpty else { return [] }

        // 融合（OpenClaw hybrid.ts）：关键词得分先按"相对最强命中"折算，并且不超过最好的向量得分，
        // 避免一个只是碰巧含有几个常见词的块压过语义上真正相关的块。
        let bestVector = merged.values.compactMap(\.vector).max() ?? 0
        func relevance(_ score: Double) -> Double { score >= 1 ? .infinity : score / (1 - score) }
        let strongest = merged.values.compactMap(\.keyword).map(relevance).max() ?? 0
        var scored: [(candidate: Candidate, score: Double)] = merged.values.map { candidate in
            guard vectorUsed else { return (candidate, candidate.keyword ?? 0) }
            var keyword = candidate.keyword ?? 0
            if keyword > 0, strongest > 0 {
                let share = keyword >= 1 ? 1 : relevance(keyword) / strongest
                keyword = min(keyword, share * bestVector)
            }
            return (candidate, options.vectorWeight * (candidate.vector ?? 0) + options.textWeight * keyword)
        }

        // 门槛按衰减前的得分判断：时间只影响先后，不把旧内容排除在外。
        // 只有关键词时，再去掉远弱于最佳命中的结果（OR 查询会带回只沾到一个常见词的块）。
        let best = scored.map(\.score).max() ?? 0
        scored = scored.filter { $0.score >= options.minScore && (vectorUsed || $0.score >= best * 0.6) }
        guard !scored.isEmpty else { return [] }

        let decayed = scored.map { item -> (candidate: Candidate, score: Double, ranking: Double) in
            (item.candidate, item.score, item.score * Self.decay(day: item.candidate.row.day, options: options))
        }.sorted { ($0.ranking, $0.candidate.row.id) > ($1.ranking, $1.candidate.row.id) }

        return Self.diversify(decayed, lambda: options.mmrLambda, limit: options.maxResults).map { item in
            let row = item.candidate.row
            return MemoryChunkHit(
                id: row.id, file: row.file, category: MemoryCategory(file: row.file), heading: row.heading,
                content: row.content, day: row.day, score: item.score,
                vectorScore: item.candidate.vector, keywordScore: item.candidate.keyword
            )
        }
    }

    /// 给还没有向量的块补算向量。分批进行，每批之间可以被取消；返回这次算了多少块。
    /// 向量模型不可用时什么都不做。
    @discardableResult
    public func embedPending(using embedder: any TextEmbedder, batchSize: Int = 16, limit: Int = 2000) async throws -> Int {
        guard embedder.isAvailable else { return 0 }
        let model = embedder.identifier
        // 不再对应任何块的向量（文件改了、删了，或换过模型）直接清掉，索引不会无限增长。
        try await db.writer.write { db in
            try db.execute(sql: "DELETE FROM embedding WHERE model != ? OR hash NOT IN (SELECT hash FROM chunk)", arguments: [model])
        }
        var done = 0
        while done < limit {
            try Task.checkCancellation()
            let pending: [(hash: String, text: String)] = try await db.writer.read { db in
                try Row.fetchAll(db, sql: """
                    SELECT c.hash, c.heading, c.content FROM chunk c
                    WHERE NOT EXISTS (SELECT 1 FROM embedding e WHERE e.model = ? AND e.hash = c.hash)
                    GROUP BY c.hash LIMIT ?
                    """, arguments: [model, batchSize]).map { row in
                    (row["hash"], MemoryChunker.embeddingText(heading: row["heading"], content: row["content"]))
                }
            }
            guard !pending.isEmpty else { break }
            let vectors = try await embedder.embed(pending.map(\.text), kind: .passage)
            guard vectors.count == pending.count else { break }
            try await db.writer.write { db in
                for (item, vector) in zip(pending, vectors) {
                    try db.execute(
                        sql: "INSERT OR REPLACE INTO embedding (model, hash, vector) VALUES (?, ?, ?)",
                        arguments: [model, item.hash, Self.encode(vector)]
                    )
                }
            }
            done += pending.count
        }
        return done
    }

    public func embeddingStatus(model: String) throws -> EmbeddingStatus {
        try db.writer.read { db in
            EmbeddingStatus(
                chunks: try Int.fetchOne(db, sql: "SELECT COUNT(DISTINCT hash) FROM chunk") ?? 0,
                embedded: try Int.fetchOne(db, sql: """
                    SELECT COUNT(*) FROM embedding e WHERE e.model = ? AND e.hash IN (SELECT hash FROM chunk)
                    """, arguments: [model]) ?? 0
            )
        }
    }

    // MARK: - Legs

    struct ChunkRow {
        let id: Int64
        let file: String
        let heading: String
        let content: String
        let day: Date?
        let terms: String

        init(_ row: Row) {
            id = row["id"]
            file = row["file"]
            heading = row["heading"]
            content = row["content"]
            day = row["day"]
            terms = row["terms"]
        }
    }

    struct Candidate {
        let row: ChunkRow
        var keyword: Double?
        var vector: Double?
    }

    private func filter(_ options: MemorySearchOptions) -> (sql: String, arguments: [any DatabaseValueConvertible]) {
        var filters: [String] = []
        var arguments: [any DatabaseValueConvertible] = []
        if let categories = options.categories {
            var parts: [String] = []
            for category in MemoryCategory.allCases where categories.contains(category) {
                if let file = category.file {
                    parts.append("c.file = ?")
                    arguments.append(file)
                } else {
                    parts.append("c.file LIKE '\(MemoryDirectory.dailyDirectory)/%'")
                }
            }
            filters.append("(" + (parts.isEmpty ? "0" : parts.joined(separator: " OR ")) + ")")
        }
        if let range = options.dayRange {
            filters.append("c.day IS NOT NULL AND c.day >= ? AND c.day <= ?")
            arguments.append(range.lowerBound)
            arguments.append(range.upperBound)
        }
        return (filters.isEmpty ? "" : " AND " + filters.joined(separator: " AND "), arguments)
    }

    /// 关键词一路：各检索词之间是"或"，由 BM25 排序（少见的词权重高）。
    /// 得分 = BM25 折算到 0…1，再按"问题里的词命中了多少"加成（OpenClaw 的 lexical boost）。
    private func keywordCandidates(terms: [String], options: MemorySearchOptions, limit: Int) throws -> [Candidate] {
        guard !terms.isEmpty else { return [] }
        let pattern = terms.map { "\"" + $0.replacingOccurrences(of: "\"", with: "") + "\"" }.joined(separator: " OR ")
        let extra = filter(options)
        let rows = try db.writer.read { db in
            try Row.fetchAll(db, sql: """
                SELECT c.id, c.file, c.heading, c.content, c.day, c.terms, bm25(chunk_fts) AS rank
                FROM chunk_fts JOIN chunk c ON c.id = chunk_fts.rowid
                WHERE chunk_fts MATCH ?\(extra.sql)
                ORDER BY rank LIMIT ?
                """, arguments: StatementArguments([pattern] + extra.arguments + [limit]))
        }
        return rows.map { row in
            let chunk = ChunkRow(row)
            let present = Set(chunk.terms.split(separator: " ").map(String.init))
            let headingTerms = Set(MemoryTerms.indexTerms(chunk.heading))
            let coverage = Double(terms.filter(present.contains).count) / Double(terms.count)
            let boost = coverage * 0.45 + (terms.contains(where: headingTerms.contains) ? 0.18 : 0)
            let score = (Self.score(bm25: row["rank"]) + boost) / (1 + boost)
            return Candidate(row: chunk, keyword: score, vector: nil)
        }
    }

    /// 向量一路：把（过滤后的）全部向量读出来逐个算点积。个人记忆是几千块的量级，
    /// 384 维的暴力扫描在毫秒级，不值得为此引入向量索引扩展。
    /// 返回进入候选的块（通过 `calibrate` 的门槛），以及所有块换算后的语义得分（不做门槛，供关键词候选补分）。
    private func vectorCandidates(
        _ query: [Float], embedder: any TextEmbedder, options: MemorySearchOptions, limit: Int
    ) throws -> (hits: [(ChunkRow, Double)], similarities: [Int64: Double]) {
        let extra = filter(options)
        var scored: [(Int64, Double)] = try db.writer.read { db in
            var result: [(Int64, Double)] = []
            let rows = try Row.fetchCursor(db, sql: """
                SELECT c.id, e.vector FROM chunk c JOIN embedding e ON e.hash = c.hash AND e.model = ?
                WHERE 1\(extra.sql)
                """, arguments: StatementArguments([embedder.identifier] + extra.arguments))
            while let row = try rows.next() {
                let data: Data = row["vector"]
                guard data.count == query.count * MemoryLayout<Float>.size else { continue }
                let cosine = data.withUnsafeBytes { raw -> Float in
                    var dot: Float = 0
                    vDSP_dotpr(query, 1, raw.bindMemory(to: Float.self).baseAddress!, 1, &dot, vDSP_Length(query.count))
                    return dot
                }
                result.append((row["id"], Double(cosine)))
            }
            return result
        }
        let similarities = Dictionary(
            scored.map { ($0.0, Self.linear($0.1, range: embedder.similarityRange)) }, uniquingKeysWith: { a, _ in a }
        )
        scored = Self.calibrate(scored, range: embedder.similarityRange, options: options)
        let top = scored.sorted { $0.1 > $1.1 }.prefix(limit)
        guard !top.isEmpty else { return ([], similarities) }
        let byId = Dictionary(uniqueKeysWithValues: top.map { ($0.0, $0.1) })
        let rows = try db.writer.read { db in
            try Row.fetchAll(db, sql: """
                SELECT id, file, heading, content, day, terms FROM chunk
                WHERE id IN (\(top.map { String($0.0) }.joined(separator: ",")))
                """)
        }
        return (rows.map { row in
            let chunk = ChunkRow(row)
            return (chunk, byId[chunk.id] ?? 0)
        }, similarities)
    }

    private static func queryVector(_ query: String, embedder: any TextEmbedder, timeout: TimeInterval) async -> [Float]? {
        await withTaskGroup(of: [Float]?.self) { group in
            group.addTask { try? await embedder.embed([query], kind: .query).first }
            group.addTask {
                try? await Task.sleep(for: .seconds(timeout))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    // MARK: - Scoring

    /// 把余弦相似度换算成 0…1 的语义得分：按模型给出的有效区间线性换算。
    ///
    /// 另外要求这个块在本次查询里明显高于索引的平均水平（`vectorMinZ` 个标准差）：
    /// 有些问题（很短、很泛）与所有内容的相似度都偏高，光看绝对值会把一批不相干的块放进来。
    /// 块太少时分布不可靠，不做这项检查。
    static func calibrate(
        _ scored: [(Int64, Double)], range: ClosedRange<Float>, options: MemorySearchOptions
    ) -> [(Int64, Double)] {
        guard !scored.isEmpty else { return [] }
        let values = scored.map(\.1)
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)
        let deviation = max(variance.squareRoot(), 0.01)
        return scored.compactMap { id, cosine in
            if scored.count >= 30, (cosine - mean) / deviation < options.vectorMinZ { return nil }
            let score = linear(cosine, range: range)
            return score > 0 ? (id, score) : nil
        }
    }

    /// 余弦相似度按模型的有效区间线性换算到 0…1。
    static func linear(_ cosine: Double, range: ClosedRange<Float>) -> Double {
        let (low, high) = (Double(range.lowerBound), Double(range.upperBound))
        return min(1, max(0, (cosine - low) / max(high - low, 0.01)))
    }

    /// FTS5 的 bm25() 越小（越负）越相关。折算方式与 OpenClaw 的 `bm25RankToScore` 相同。
    static func score(bm25 rank: Double) -> Double {
        guard rank.isFinite else { return 1.0 / 1000 }
        if rank < 0 { return -rank / (1 - rank) }
        return 1 / (1 + rank)
    }

    /// 时间衰减：只作用于有日期的内容（daily）；长期记忆不衰减。
    static func decay(day: Date?, options: MemorySearchOptions) -> Double {
        guard let day, options.halfLifeDays > 0 else { return 1 }
        let age = max(0, options.now.timeIntervalSince(day) / 86_400)
        let decay = exp(-log(2) / options.halfLifeDays * age)
        return options.decayFloor + (1 - options.decayFloor) * decay
    }

    /// MMR：每次选"相关度高、且与已选结果不重复"的一条。相似度用词集合的 Jaccard（与 OpenClaw 相同），
    /// 不需要向量，纯关键词模式下也能去重——时间线里相邻片段常常讲的是同一件事。
    static func diversify(
        _ items: [(candidate: Candidate, score: Double, ranking: Double)], lambda: Double, limit: Int
    ) -> [(candidate: Candidate, score: Double, ranking: Double)] {
        guard items.count > 1 else { return Array(items.prefix(limit)) }
        let high = items.map(\.ranking).max() ?? 1
        let low = items.map(\.ranking).min() ?? 0
        let span = high - low
        let sets = items.map { Set($0.candidate.row.terms.split(separator: " ").map(String.init)) }
        var remaining = Array(items.indices)
        var selected: [Int] = []
        // 每个候选与已选结果的最大相似度，只在新选中一条时更新：结果与每轮重算全部相同，
        // 但取 50 条时从 O(条数² × 候选) 降到 O(条数 × 候选)。
        var closest = [Double](repeating: 0, count: items.count)
        while selected.count < limit, !remaining.isEmpty {
            var bestIndex = 0
            var bestScore = -Double.infinity
            for (offset, index) in remaining.enumerated() {
                let relevance = span > 0 ? (items[index].ranking - low) / span : 1
                let score = lambda * relevance - (1 - lambda) * closest[index]
                if score > bestScore {
                    bestScore = score
                    bestIndex = offset
                }
            }
            let chosen = remaining.remove(at: bestIndex)
            selected.append(chosen)
            for index in remaining {
                closest[index] = max(closest[index], MemoryTerms.jaccard(sets[index], sets[chosen]))
            }
        }
        return selected.map { items[$0] }
    }

    static func encode(_ vector: [Float]) -> Data {
        vector.withUnsafeBufferPointer { Data(buffer: $0) }
    }
}
