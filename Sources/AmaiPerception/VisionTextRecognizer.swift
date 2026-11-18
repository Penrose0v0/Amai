import AmaiCore
import Foundation
import Vision

/// Apple Vision 本地 OCR。`.accurate` 级别才支持中文。
public struct VisionTextRecognizer: TextRecognizer {
    public let preferredLanguages: [String]

    public init(preferredLanguages: [String] = ["zh-Hans", "zh-Hant", "en-US", "ja-JP"]) {
        self.preferredLanguages = preferredLanguages
    }

    public func recognize(jpeg: Data) async throws -> OCRResult {
        let languages = preferredLanguages
        return try await Task.detached(priority: .utility) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            if let supported = try? request.supportedRecognitionLanguages() {
                let usable = languages.filter(supported.contains)
                if !usable.isEmpty { request.recognitionLanguages = usable }
            }
            let handler = VNImageRequestHandler(data: jpeg, options: [:])
            try handler.perform([request])
            let observations = (request.results ?? []).sorted { a, b in
                // Vision 坐标原点在左下角：y 越大越靠上。
                if abs(a.boundingBox.midY - b.boundingBox.midY) > 0.01 {
                    return a.boundingBox.midY > b.boundingBox.midY
                }
                return a.boundingBox.minX < b.boundingBox.minX
            }
            let lines = observations.compactMap { obs -> OCRLine? in
                guard let candidate = obs.topCandidates(1).first else { return nil }
                let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
                return text.isEmpty ? nil : OCRLine(text: text, confidence: candidate.confidence)
            }
            return OCRResult(lines: lines)
        }.value
    }
}
