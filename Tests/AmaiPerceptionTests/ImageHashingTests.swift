import Foundation
import Testing
@testable import AmaiPerception

@Suite("ImageHashing")
struct ImageHashingTests {
    @Test("identical images hash identically")
    func identical() {
        let a = ImageHashing.dHash(SyntheticImage.make(seed: 0))
        let b = ImageHashing.dHash(SyntheticImage.make(seed: 0))
        #expect(ImageHashing.distance(a, b) == 0)
        #expect(ImageHashing.isSameScreen(a, b))
    }

    @Test("clearly different images exceed the same-screen threshold")
    func different() {
        let a = ImageHashing.dHash(SyntheticImage.make(seed: 0))
        let b = ImageHashing.dHash(SyntheticImage.make(seed: 1))
        #expect(ImageHashing.distance(a, b) > ImageHashing.sameScreenThreshold)
    }

    @Test("JPEG encoding produces a JPEG header")
    func jpeg() throws {
        let data = try JPEGEncoder.encode(SyntheticImage.make(seed: 0), quality: 0.7)
        #expect(data.count > 100)
        #expect(data[0] == 0xFF && data[1] == 0xD8)
    }
}
