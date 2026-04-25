import XCTest
@testable import Chronicle

final class ModelPricingTests: XCTestCase {

    // MARK: - Lookup

    func test_pricing_exactMatch_opus47() {
        let p = ModelPricing.pricing(for: "claude-opus-4.7")
        XCTAssertEqual(p.inputPer1M, 15.00, accuracy: 0.0001)
        XCTAssertEqual(p.outputPer1M, 75.00, accuracy: 0.0001)
    }

    func test_pricing_exactMatch_sonnet45() {
        let p = ModelPricing.pricing(for: "claude-sonnet-4.5")
        XCTAssertEqual(p.inputPer1M, 3.00, accuracy: 0.0001)
        XCTAssertEqual(p.outputPer1M, 15.00, accuracy: 0.0001)
    }

    func test_pricing_exactMatch_haiku45() {
        let p = ModelPricing.pricing(for: "claude-haiku-4.5")
        XCTAssertEqual(p.inputPer1M, 0.80, accuracy: 0.0001)
        XCTAssertEqual(p.outputPer1M, 4.00, accuracy: 0.0001)
    }

    func test_pricing_substringMatch_versionedSuffix() {
        // Real Claude Code jsonl files label assistants with a dated
        // variant — we should still resolve it.
        let p = ModelPricing.pricing(for: "claude-sonnet-4-5-20250929")
        XCTAssertEqual(p.inputPer1M, 3.00, accuracy: 0.0001)
        XCTAssertEqual(p.outputPer1M, 15.00, accuracy: 0.0001)
    }

    func test_pricing_normalisesDotsAndUnderscores() {
        let a = ModelPricing.pricing(for: "claude_opus_4_6")
        XCTAssertEqual(a.inputPer1M, 15.00, accuracy: 0.0001)
        XCTAssertEqual(a.outputPer1M, 75.00, accuracy: 0.0001)
    }

    func test_pricing_nilReturnsFallback() {
        let p = ModelPricing.pricing(for: nil)
        XCTAssertEqual(p, ModelPricing.fallback)
    }

    func test_pricing_emptyReturnsFallback() {
        let p = ModelPricing.pricing(for: "")
        XCTAssertEqual(p, ModelPricing.fallback)
    }

    func test_pricing_unknownReturnsFallback() {
        let p = ModelPricing.pricing(for: "gpt-5-xxl")
        XCTAssertEqual(p, ModelPricing.fallback)
        // Fallback tracks blended sonnet rates per contract.
        XCTAssertEqual(p.inputPer1M, 3.00, accuracy: 0.0001)
        XCTAssertEqual(p.outputPer1M, 15.00, accuracy: 0.0001)
    }

    // MARK: - Cost

    func test_cost_opus47_oneMillionEach() {
        // 1M input + 1M output on Opus 4.7 = 15 + 75 = $90.
        let c = ModelPricing.cost(inputTokens: 1_000_000,
                                   outputTokens: 1_000_000,
                                   model: "claude-opus-4.7")
        XCTAssertEqual(c, 90.0, accuracy: 0.0001)
    }

    func test_cost_sonnet45_realistic() {
        // 50k input, 20k output on Sonnet 4.5 = 0.15 + 0.30 = $0.45.
        let c = ModelPricing.cost(inputTokens: 50_000,
                                   outputTokens: 20_000,
                                   model: "claude-sonnet-4.5")
        XCTAssertEqual(c, 0.45, accuracy: 0.0001)
    }

    func test_cost_unknownUsesFallback() {
        // 1M input + 1M output on fallback (sonnet-blend) = 3 + 15 = $18.
        let c = ModelPricing.cost(inputTokens: 1_000_000,
                                   outputTokens: 1_000_000,
                                   model: "some-future-model")
        XCTAssertEqual(c, 18.0, accuracy: 0.0001)
    }

    func test_cost_negativeTokensClampToZero() {
        let c = ModelPricing.cost(inputTokens: -1_000,
                                   outputTokens: -10,
                                   model: "claude-opus-4.7")
        XCTAssertEqual(c, 0.0, accuracy: 0.0001)
    }
}
