import Foundation

/// Durable user intent about contexts. The AI/clustering layer proposes; this layer
/// records what the user *decided* and is NEVER clobbered by re-computation.
/// (Derived state stays separate from persisted user intent.)
///
/// Two kinds of durable state:
///   • assignment  key  → groupId   — "this localhost belongs in my 'api' context"
///   • label       groupId → name   — an inline rename of a context
///
/// A `groupId` is either a raw key (when the user renamed an auto-cluster in place) or a
/// user-minted id "user:<slug>" (when they created/merged into a named context).
final class ContextOverrides {

    private var assign: [String: String]   // key → groupId
    private var names:  [String: String]   // groupId → display label
    private var ignored: Set<String>       // groupIds the user removed (suppressed even if they'd re-derive)
    private let defaults: UserDefaults?
    private static let kAssign = "ctxAssign", kNames = "ctxNames", kIgnored = "ctxIgnored"

    /// Production init (UserDefaults-backed). `defaults:` is required (no default value) so a
    /// bare `ContextOverrides()` unambiguously selects the in-memory init below — tests never
    /// touch real UserDefaults.
    init(defaults: UserDefaults) {
        self.defaults = defaults
        assign = (defaults.dictionary(forKey: Self.kAssign) as? [String: String]) ?? [:]
        names  = (defaults.dictionary(forKey: Self.kNames)  as? [String: String]) ?? [:]
        ignored = Set(defaults.stringArray(forKey: Self.kIgnored) ?? [])
    }

    /// In-memory init for tests (and the default for a bare `ContextOverrides()`).
    init(assign: [String: String] = [:], names: [String: String] = [:]) {
        self.defaults = nil
        self.assign = assign
        self.names = names
        self.ignored = []
    }

    // MARK: queries (used by clustering)

    /// The durable group a key has been moved into, if any.
    func group(forKey key: String) -> String? { assign[key] }

    /// Whether a group id was explicitly named/created by the user (so it survives even
    /// as a single-app cluster — user intent outranks the ≥2-app heuristic).
    func isUserNamed(_ groupId: String) -> Bool { names[groupId] != nil || groupId.hasPrefix("user:") }

    /// The user's display label for a group, if renamed.
    func label(forGroup groupId: String) -> String? { names[groupId] }

    /// Keys the user has explicitly filed into a group (used to tell if a context still has any
    /// members, independent of which items are open right now).
    func assignedKeys(toGroup groupId: String) -> [String] {
        assign.filter { $0.value == groupId }.map { $0.key }
    }

    // MARK: mutations

    /// Move a key into a named context (durable). Creates the group id if needed.
    func assign(key: String, toGroup groupId: String) { assign[key] = groupId; persist() }

    /// Inline rename of a context. If `groupId` is a raw key, this both names it and
    /// marks it user-owned so it persists.
    func rename(_ groupId: String, to label: String) {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { names[groupId] = nil } else { names[groupId] = trimmed }
        persist()
    }

    /// Forget a key's assignment (back to auto-clustering for that key).
    func clearAssignment(forKey key: String) { assign[key] = nil; persist() }

    // MARK: removal

    /// True if the user removed this group (it must not surface even if it would re-derive).
    func isIgnored(_ groupId: String) -> Bool { ignored.contains(groupId) }

    /// Remove a context: forget every item filed into it, drop its name, and suppress it so an
    /// auto-cluster with the same key won't pop back. (Reset by re-deriving fresh only via clearIgnore.)
    func removeGroup(_ groupId: String) {
        for (k, v) in assign where v == groupId { assign[k] = nil }
        names[groupId] = nil
        ignored.insert(groupId)
        persist()
    }
    func clearIgnore(_ groupId: String) { ignored.remove(groupId); persist() }

    private func persist() {
        defaults?.set(assign, forKey: Self.kAssign)
        defaults?.set(names,  forKey: Self.kNames)
        defaults?.set(Array(ignored), forKey: Self.kIgnored)
    }
}
