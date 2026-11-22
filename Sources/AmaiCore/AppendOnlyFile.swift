import Foundation

/// 只追加的行文件（JSONL）的写入。
///
/// 进程在写一行的中途退出会留下没有换行结尾的半行。直接在后面追加，下一条记录就会和半行粘在同一行，
/// 读取时整行无法解析而被丢弃——丢的是新写的那条。这里在追加前检查文件末尾，必要时先补一个换行，
/// 让损坏只限于那半行本身。
public enum AppendOnlyFile {
    /// 把 `data`（应以换行结尾）追加到 `url`；文件不存在时原子创建。
    public static func append(_ data: Data, to url: URL) throws {
        guard let handle = try? FileHandle(forUpdating: url) else {
            try data.write(to: url, options: .atomic)
            return
        }
        defer { try? handle.close() }
        let end = try handle.seekToEnd()
        var payload = data
        if end > 0 {
            try handle.seek(toOffset: end - 1)
            if try handle.read(upToCount: 1) != Data([0x0A]) {
                payload.insert(0x0A, at: payload.startIndex)
            }
            try handle.seekToEnd()
        }
        try handle.write(contentsOf: payload)
    }
}
