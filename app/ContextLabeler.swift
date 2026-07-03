import Foundation

/// Proposes human labels for computed contexts. Behind a protocol so the on-device AI
/// (FoundationModels, see ContextLabelerAI.swift) is swappable with a deterministic stub
/// for tests and for machines where the model is unavailable.
protocol ContextLabeler {
    /// Returns groupId → suggested label. May omit groups it has no opinion on.
    /// Callers apply suggestions ONLY where the user hasn't renamed (durable wins).
    func label(_ contexts: [WorkContext]) async -> [String: String]
}

/// Fallback labeler: keeps the derived label (identity). Used when the on-device model is
/// unavailable, and as the deterministic test double.
struct DeterministicLabeler: ContextLabeler {
    func label(_ contexts: [WorkContext]) async -> [String: String] {
        var out: [String: String] = [:]
        for c in contexts { out[c.id] = c.label }
        return out
    }
}
