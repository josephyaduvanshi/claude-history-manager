import Foundation

/// Pricing row for a single Claude model (USD per 1M tokens).
/// Kept as a plain value type so the table can live as a static `let`
/// and tests can assert exact amounts.
public struct ModelPricing: Sendable, Equatable {
    public let model: String
    public let inputPer1M: Double
    public let outputPer1M: Double

    public init(model: String, inputPer1M: Double, outputPer1M: Double) {
        self.model = model
        self.inputPer1M = inputPer1M
        self.outputPer1M = outputPer1M
    }

    // MARK: - Table

    /// The known-models table. Lookup is a forgiving substring match on the
    /// model ID so versioned strings like
    /// `"claude-sonnet-4-5-20250929"` or `"claude-opus-4-6"` still resolve.
    public static let table: [ModelPricing] = [
        // Claude 4.x family
        ModelPricing(model: "claude-opus-4.7",     inputPer1M: 15.00, outputPer1M: 75.00),
        ModelPricing(model: "claude-opus-4.6",     inputPer1M: 15.00, outputPer1M: 75.00),
        ModelPricing(model: "claude-sonnet-4.6",   inputPer1M: 3.00,  outputPer1M: 15.00),
        ModelPricing(model: "claude-sonnet-4.5",   inputPer1M: 3.00,  outputPer1M: 15.00),
        ModelPricing(model: "claude-haiku-4.5",    inputPer1M: 0.80,  outputPer1M: 4.00),

        // Claude 3.5 family (legacy; kept so older sessions still cost correctly).
        ModelPricing(model: "claude-3-5-sonnet",   inputPer1M: 3.00,  outputPer1M: 15.00),
        ModelPricing(model: "claude-3-5-haiku",    inputPer1M: 0.80,  outputPer1M: 4.00),
    ]

    /// Fallback row for unknown / missing model strings. Approximates a
    /// blended Sonnet rate so cost estimates stay reasonable for real
    /// coding sessions that don't label their model.
    public static let fallback = ModelPricing(
        model: "unknown", inputPer1M: 3.00, outputPer1M: 15.00
    )

    // MARK: - Resolution

    /// Resolves a model ID to its pricing row. Performs a case-insensitive
    /// match, preferring exact hits then longest substring hit. Returns
    /// `.fallback` when nothing matches (including nil / empty input).
    public static func pricing(for modelID: String?) -> ModelPricing {
        guard let raw = modelID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return fallback
        }
        let needle = normalize(raw)

        // Exact normalized match first.
        if let exact = table.first(where: { normalize($0.model) == needle }) {
            return exact
        }

        // Try each row as either a prefix of or a substring within the input.
        // Real model IDs often carry a date suffix (e.g.
        // `claude-sonnet-4-6-20260115`); substring matching covers both
        // directions. Prefer the longest match so "claude-opus-4.6" wins
        // over "claude-opus" when both are in the table.
        var best: ModelPricing? = nil
        var bestLen = 0
        for row in table {
            let n = normalize(row.model)
            if needle.contains(n) || n.contains(needle) {
                if n.count > bestLen {
                    best = row
                    bestLen = n.count
                }
            }
        }
        if let best { return best }
        return fallback
    }

    /// USD cost of a (input,output) token usage under the given model.
    /// Token counts are clamped to non-negative.
    public static func cost(inputTokens: Int, outputTokens: Int, model: String?) -> Double {
        let row = pricing(for: model)
        let inTokens  = Double(max(0, inputTokens))
        let outTokens = Double(max(0, outputTokens))
        return (inTokens / 1_000_000.0) * row.inputPer1M
             + (outTokens / 1_000_000.0) * row.outputPer1M
    }

    /// Normalizes a model ID for lookup: lowercase; replace `_`, `.`, and
    /// whitespace with `-`; collapse repeated `-`.
    private static func normalize(_ s: String) -> String {
        var out = s.lowercased()
        out = out.replacingOccurrences(of: "_", with: "-")
        out = out.replacingOccurrences(of: ".", with: "-")
        out = out.replacingOccurrences(of: " ", with: "-")
        while out.contains("--") {
            out = out.replacingOccurrences(of: "--", with: "-")
        }
        return out
    }
}
