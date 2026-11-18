import Foundation
import GRDB

/// 历史列表里的一行。
public struct SessionSummary: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let title: String
    public let updatedAt: Date
}

/// 对话记录的本地存储（SQLite，移植自 Eira 的 ChatSessionStore）。
///
/// 只保存界面上看到的内容：用户的问题、助手的回答和回答引用的记忆来源。
/// 当时附带的屏幕上下文、截图和工具往返不保存。用户可以删除单个对话或全部对话；
/// 超过上限的旧对话自动清理。它不是记忆的一部分，记忆整理不读取它。
public final class ChatSessionStore: Sendable {
    /// 最多保留的对话数。
    public static let maxSessions = 200

    private let database: DatabaseQueue

    public init(path: String) throws {
        database = try DatabaseQueue(path: path)
        try migrate()
    }

    public static func inMemory() throws -> ChatSessionStore {
        try ChatSessionStore(queue: DatabaseQueue())
    }

    private init(queue: DatabaseQueue) throws {
        database = queue
        try migrate()
    }

    private func migrate() throws {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "sessions") { t in
                t.column("id", .text).primaryKey()
                t.column("title", .text).notNull()
                t.column("createdAt", .double).notNull()
                t.column("updatedAt", .double).notNull()
            }
            try db.create(table: "messages") { t in
                t.column("id", .text).primaryKey()
                t.column("sessionId", .text).notNull().indexed()
                    .references("sessions", onDelete: .cascade)
                t.column("role", .text).notNull()
                t.column("content", .text).notNull()
                t.column("sources", .text).notNull().defaults(to: "[]")
                t.column("createdAt", .double).notNull()
            }
        }
        try migrator.migrate(database)
    }

    /// 保存一条消息。对话的第一条消息会创建对话，标题取自 `suggestedTitle`。
    public func save(_ message: DisplayMessage, in session: UUID, suggestedTitle: String? = nil) throws {
        let sources = String(decoding: (try? JSONEncoder().encode(message.sources)) ?? Data("[]".utf8), as: UTF8.self)
        let now = Date().timeIntervalSince1970
        try database.write { db in
            let exists = try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM sessions WHERE id = ?)", arguments: [session.uuidString]) ?? false
            if exists {
                try db.execute(sql: "UPDATE sessions SET updatedAt = ? WHERE id = ?", arguments: [now, session.uuidString])
            } else {
                try db.execute(
                    sql: "INSERT INTO sessions (id, title, createdAt, updatedAt) VALUES (?, ?, ?, ?)",
                    arguments: [session.uuidString, Self.title(from: suggestedTitle ?? message.text), now, now]
                )
            }
            try db.execute(
                sql: "INSERT OR REPLACE INTO messages (id, sessionId, role, content, sources, createdAt) VALUES (?, ?, ?, ?, ?, ?)",
                arguments: [message.id.uuidString, session.uuidString, message.role.rawValue, message.text, sources, message.createdAt.timeIntervalSince1970]
            )
        }
    }

    public func messages(in session: UUID) throws -> [DisplayMessage] {
        try database.read { db in
            try Row.fetchAll(
                db, sql: "SELECT * FROM messages WHERE sessionId = ? ORDER BY createdAt, rowid", arguments: [session.uuidString]
            ).compactMap { row in
                guard let id = UUID(uuidString: row["id"]), let role = DisplayMessage.Role(rawValue: row["role"]) else { return nil }
                let sources = (try? JSONDecoder().decode([MemorySource].self, from: Data((row["sources"] as String).utf8))) ?? []
                return DisplayMessage(
                    id: id, role: role, text: row["content"], sources: sources,
                    createdAt: Date(timeIntervalSince1970: row["createdAt"])
                )
            }
        }
    }

    public func recentSessions(limit: Int = 50) throws -> [SessionSummary] {
        try database.read { db in
            try Row.fetchAll(db, sql: "SELECT id, title, updatedAt FROM sessions ORDER BY updatedAt DESC LIMIT ?", arguments: [limit])
                .compactMap { row in
                    UUID(uuidString: row["id"]).map {
                        SessionSummary(id: $0, title: row["title"], updatedAt: Date(timeIntervalSince1970: row["updatedAt"]))
                    }
                }
        }
    }

    /// 删除一条消息（重新生成时撤回旧的回答）。
    public func deleteMessage(_ id: UUID) throws {
        try database.write { db in
            try db.execute(sql: "DELETE FROM messages WHERE id = ?", arguments: [id.uuidString])
        }
    }

    public func deleteSession(_ session: UUID) throws {
        try database.write { db in
            try db.execute(sql: "DELETE FROM messages WHERE sessionId = ?", arguments: [session.uuidString])
            try db.execute(sql: "DELETE FROM sessions WHERE id = ?", arguments: [session.uuidString])
        }
    }

    public func deleteAll() throws {
        try database.write { db in
            try db.execute(sql: "DELETE FROM messages")
            try db.execute(sql: "DELETE FROM sessions")
        }
    }

    /// 删除超出上限的最旧对话。
    public func prune(keeping limit: Int = ChatSessionStore.maxSessions) throws {
        try database.write { db in
            let stale = try String.fetchAll(
                db, sql: "SELECT id FROM sessions ORDER BY updatedAt DESC LIMIT -1 OFFSET ?", arguments: [limit]
            )
            for id in stale {
                try db.execute(sql: "DELETE FROM messages WHERE sessionId = ?", arguments: [id])
                try db.execute(sql: "DELETE FROM sessions WHERE id = ?", arguments: [id])
            }
        }
    }

    static func title(from text: String) -> String {
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n").first.map(String.init) ?? ""
        return line.count > 60 ? String(line.prefix(60)) + "…" : line
    }
}
