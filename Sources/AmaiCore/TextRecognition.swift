import Foundation

// 文字识别的数据契约。实现（Apple Vision）在感知层：后台抽取与交互式屏幕读取共用同一个识别器。

public struct OCRLine: Codable, Sendable, Equatable {
    public let text: String
    public let confidence: Float

    public init(text: String, confidence: Float) {
        self.text = text
        self.confidence = confidence
    }
}

public struct OCRResult: Sendable, Equatable {
    /// 从上到下、从左到右排列。
    public let lines: [OCRLine]

    public init(lines: [OCRLine]) {
        self.lines = lines
    }

    public var text: String { lines.map(\.text).joined(separator: "\n") }

    public var meanConfidence: Double {
        guard !lines.isEmpty else { return 0 }
        return lines.map { Double($0.confidence) }.reduce(0, +) / Double(lines.count)
    }
}

public protocol TextRecognizer: Sendable {
    func recognize(jpeg: Data) async throws -> OCRResult
}
