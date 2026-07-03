import Foundation
import FoundationModels

/// On-device labeler using Apple's FoundationModels (macOS 26). Fully local — nothing leaves
/// the machine. Falls back to identity (derived labels) when the model is unavailable, so the
/// feature degrades gracefully on older OSes / unsupported hardware.
///
/// Used through the ContextLabeler protocol; never referenced by the test target.
@available(macOS 26, *)
struct AIContextLabeler: ContextLabeler {

    /// Whether the on-device model can run right now.
    static var isAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    @Generable
    struct Labeling {
        @Guide(description: "One label per input context, in the same order. 1–2 words, Title Case, no punctuation.")
        var labels: [String]
    }

    func label(_ contexts: [WorkContext]) async -> [String: String] {
        guard Self.isAvailable, !contexts.isEmpty else { return [:] }

        // Compact, deterministic prompt: each context as apps + a few sample titles.
        let lines = contexts.enumerated().map { i, c -> String in
            let titles = c.members.prefix(4).map { "\"\($0.title)\"" }.joined(separator: ", ")
            return "\(i + 1). apps: \(c.apps.joined(separator: ", ")); items: \(titles)"
        }.joined(separator: "\n")

        let prompt = """
        Below are groups of open windows/tabs that belong to the same task. Give each group a \
        short, human label naming the project or activity (1–2 words). Return labels in order.

        \(lines)
        """

        do {
            let session = LanguageModelSession()
            let result = try await session.respond(to: prompt, generating: Labeling.self)
            let labels = result.content.labels
            var out: [String: String] = [:]
            for (i, c) in contexts.enumerated() where i < labels.count {
                let clean = labels[i].trimmingCharacters(in: .whitespacesAndNewlines)
                if !clean.isEmpty { out[c.id] = clean }
            }
            return out
        } catch {
            return [:]   // any model error → keep derived labels
        }
    }
}

/// Picks the on-device labeler when available, else the deterministic fallback.
func makeContextLabeler() -> ContextLabeler {
    if #available(macOS 26, *), AIContextLabeler.isAvailable { return AIContextLabeler() }
    return DeterministicLabeler()
}
