import Foundation

/// Coordinates context computation. Owns the durable overrides, an AI-label cache, and the
/// current cluster snapshot. Recomputes deterministically (fast, synchronous) on demand, then
/// refines labels with the on-device model in the background. Debounced so a burst of app
/// activations collapses into one recompute.
///
/// AppKit-free by design: callers inject `gatherItems` (the adapter scan) so the whole flow is
/// driven by closures and unit-testable.
final class ContextStore {

    private let gatherItems: () -> [ContextItem]
    private let overrides: ContextOverrides
    private let labeler: ContextLabeler
    private let defaults: UserDefaults
    private static let kAILabels = "ctxAILabels"
    private static let kAISig = "ctxAISig"
    private static let kOrder = "ctxOrder"

    private var aiLabels: [String: String]
    private var aiSig: [String: String]           // groupId → content signature the AI name was made for
    private var displayOrder: [String]            // groupIds in creation/first-seen order (persisted)
    private var lastItems: [ContextItem] = []     // last gathered snapshot, for rescan-free reclustering

    /// Latest snapshot. Read on main; written on main via `publish`.
    private(set) var contexts: [WorkContext] = []
    /// Called on the main thread whenever `contexts` changes.
    var onChange: (() -> Void)?

    init(gatherItems: @escaping () -> [ContextItem],
         overrides: ContextOverrides,
         labeler: ContextLabeler,
         defaults: UserDefaults = .standard) {
        self.gatherItems = gatherItems
        self.overrides = overrides
        self.labeler = labeler
        self.defaults = defaults
        self.aiLabels = (defaults.dictionary(forKey: Self.kAILabels) as? [String: String]) ?? [:]
        self.aiSig = (defaults.dictionary(forKey: Self.kAISig) as? [String: String]) ?? [:]
        self.displayOrder = (defaults.stringArray(forKey: Self.kOrder)) ?? []
    }

    // MARK: recompute

    /// Deterministic cluster now (using cached AI labels), publish, then refine labels async.
    /// Re-scans all apps — use `recluster()` for grouping-only changes that don't need a rescan.
    func recompute() { ingest(gatherItems()) }

    /// Adopt an externally-gathered snapshot (e.g. the panel's live scan on summon) — keeps the
    /// store in sync with exactly what's shown, without a second AppleScript scan. Clusters,
    /// publishes, and refines labels. Call once per summon, not per keystroke.
    func ingest(_ items: [ContextItem]) {
        lastItems = items
        let clustered = ContextEngine.cluster(items, overrides: overrides, aiLabels: aiLabels)
        publish(clustered)
        refineLabels(for: clustered)
    }

    /// Re-cluster from the most recently gathered items WITHOUT re-scanning (no AppleScript) and
    /// WITHOUT kicking AI labeling. For cheap grouping mutations (membership toggle, rename) that
    /// must feel instant; AI labels settle on the next full `recompute`.
    private func recluster() {
        publish(ContextEngine.cluster(lastItems, overrides: overrides, aiLabels: aiLabels))
    }

    /// Content signature of a context: its set of apps + keys (NOT titles, so browsing within the
    /// same sites doesn't churn it). The AI name is regenerated only when this changes.
    private func signature(_ c: WorkContext) -> String {
        let apps = Set(c.members.map { $0.app }).sorted()
        let keys = Set(c.members.map { $0.key }).sorted()
        return apps.joined(separator: ",") + "|" + keys.joined(separator: ",")
    }

    private func refineLabels(for clustered: [WorkContext]) {
        // On-device AI naming is OPT-IN (off by default): only run the model when the user has
        // enabled it in Preferences ▸ Contexts. When off, contexts keep their derived labels.
        // Reads the store's own `defaults` (=.standard in the app, which the toggle writes).
        guard defaults.bool(forKey: "ctxAILabeling") else { return }
        // Name a context when it's NEW or its composition CHANGED (apps/keys), but not on every
        // compute — the model is non-deterministic, so re-labeling unchanged contexts would make
        // names (and sort order) flicker. User renames always win and are never touched.
        let needsLabel = clustered.filter { overrides.label(forGroup: $0.id) == nil && aiSig[$0.id] != signature($0) }
        guard !needsLabel.isEmpty else { return }
        Task { [weak self] in
            guard let self else { return }
            let suggestions = await self.labeler.label(needsLabel)
            guard !suggestions.isEmpty else { return }
            var changed = false
            for c in needsLabel {
                guard let label = suggestions[c.id], self.overrides.label(forGroup: c.id) == nil else { continue }
                self.aiLabels[c.id] = label
                self.aiSig[c.id] = self.signature(c)        // remember what we named, so we re-name only on change
                changed = true
            }
            guard changed else { return }
            self.defaults.set(self.aiSig, forKey: Self.kAISig)
            self.defaults.set(self.aiLabels, forKey: Self.kAILabels)
            let items = self.gatherItems()
            let relabeled = ContextEngine.cluster(items, overrides: self.overrides, aiLabels: self.aiLabels)
            self.publish(relabeled)
        }
    }

    /// Stable display order = creation/first-seen order: each context keeps its slot, new ones stack
    /// at the bottom. Builds spatial memory — contexts never jump around. (Runs on main only.)
    private func stableOrder(_ cs: [WorkContext]) -> [WorkContext] {
        var appended = false
        for c in cs where !displayOrder.contains(c.id) { displayOrder.append(c.id); appended = true }
        if appended { defaults.set(displayOrder, forKey: Self.kOrder) }
        let rank = Dictionary(displayOrder.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        return cs.sorted { (rank[$0.id] ?? Int.max) < (rank[$1.id] ?? Int.max) }
    }

    private func publish(_ next: [WorkContext]) {
        let apply = { [weak self] in
            guard let self else { return }
            let ordered = self.stableOrder(next)            // creation order; never reshuffles
            guard ordered != self.contexts else { return }  // nothing changed → no redraw, no onChange
            self.contexts = ordered
            self.onChange?()
        }
        if Thread.isMainThread { apply() } else { DispatchQueue.main.async(execute: apply) }
    }

    // MARK: user actions

    /// Inline rename of a context (durable). Reclusters immediately so the UI reflects it.
    func rename(_ groupId: String, to label: String) {
        overrides.rename(groupId, to: label)
        recluster()
    }

    // MARK: user-created contexts + manual membership

    /// Create a user context and return its group id ("user:<slug>"). Empty membership until the
    /// user adds items; it won't appear in the list until it has at least one member.
    /// The id must be UNIQUE — the placeholder name ("New context") always slugs the same, so
    /// without disambiguation every new context would reuse one id and merge into (replace) the last.
    func createContext(named name: String) -> String {
        let base = "user:" + Self.slug(name)
        var id = base, n = 2
        while overrides.label(forGroup: id) != nil || overrides.isIgnored(id) {
            id = "\(base)-\(n)"; n += 1   // e.g. user:new-context, user:new-context-2, …
        }
        overrides.rename(id, to: name)    // marks it user-owned (shows even as a single app)
        return id
    }

    /// Display name for a group even when it has no members yet (used by the pick/edit header).
    func displayName(forGroup id: String) -> String {
        overrides.label(forGroup: id) ?? aiLabels[id] ?? ContextKey.displayLabel(id)
    }

    /// Whether THIS specific item is filed into a group (per-item, not by its shared cluster key).
    func isMember(_ item: ContextItem, of group: String) -> Bool {
        overrides.group(forKey: ContextKey.itemKey(item)) == group
    }

    /// Toggle ONE item's membership in a context (per-item key, so siblings sharing its project/site
    /// key are unaffected). `member: false` removes it; a naturally-keyed item returns to auto-clustering.
    func setMembership(_ item: ContextItem, in group: String, member: Bool) {
        let k = ContextKey.itemKey(item)
        if member { overrides.assign(key: k, toGroup: group) }
        else { overrides.clearAssignment(forKey: k) }
        recluster()                            // grouping-only change → no rescan
    }

    /// Remove a context entirely — forget its members, drop its name, and suppress re-derivation.
    func removeContext(_ group: String) {
        overrides.removeGroup(group)
        recluster()
    }

    /// Drop a user context that ended up with no members (e.g. created then abandoned).
    func discardIfEmpty(_ group: String) {
        guard group.hasPrefix("user:"), overrides.assignedKeys(toGroup: group).isEmpty else { return }
        overrides.rename(group, to: "")       // clear the dangling name; nothing references it
        recluster()
    }

    /// name → "slug": lowercase, non-alphanumerics collapsed to single dashes, trimmed.
    static func slug(_ name: String) -> String {
        var out = "", lastDash = false
        for ch in name.lowercased() {
            if ch.isLetter || ch.isNumber { out.append(ch); lastDash = false }
            else if !lastDash { out.append("-"); lastDash = true }
        }
        let trimmed = out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "context" : trimmed
    }
}
