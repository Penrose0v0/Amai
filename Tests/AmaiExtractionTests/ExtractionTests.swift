import Foundation
import Testing
@testable import AmaiExtraction

@Suite("ModelProvider contracts")
struct ModelProviderTests {
    @Test("ModelRequest defaults")
    func requestDefaults() {
        let request = ModelRequest(cacheable: "system", dynamic: "now")
        #expect(request.images.isEmpty)
        #expect(request.maxTokens == 1024)
    }

    @Test("default local model tag is a Gemma 4 MLX build")
    func defaultModelTag() {
        #expect(LocalInferenceBackend.defaultModelTag.hasPrefix("mlx-community/gemma-4"))
        #expect(LocalInferenceBackend.name == "mlx-swift-lm")
    }
}
