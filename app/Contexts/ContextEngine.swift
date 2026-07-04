import Foundation

/// A computed working context: a set of items (across apps) that share a key or have been
/// placed together by the user. Members keep their app, so the UI can group-by-app inside.
struct WorkContext: Equatable {
    let id: String          // groupId — raw key or "user:<slug>"
    let label: String       // display name (user rename wins, else derived)
    let aiLabeled: Bool     // label came from the on-device model (not a user rename / raw key)
    let members: [Ref]      // lightweight item refs, original order preserved

    /// Minimal item snapshot the engine needs — decouples clustering from TabRef/AppKit.
    struct Ref: Equatable {
        let app: String
        let title: String
        let key: String
    }

    var apps: [String] {                       // distinct apps, first-seen order
        var seen = Set<String>(), out = [String]()
        for m in members where !seen.contains(m.app) { seen.insert(m.app); out.append(m.app) }
        return out
    }
}

/// Deterministic L1 clustering: group keyable items, apply durable user overrides, keep a
/// group when it spans ≥2 apps OR the user named it. No AI here — this is the stable spine
/// the AI labeling layer (P3) decorates and the override layer (P4) corrects.
enum ContextEngine {

    /// `aiLabels` (groupId → label) are applied only where the user hasn't renamed —
    /// durable user intent always wins. Defaults empty (pure deterministic clustering).
    static func cluster(_ items: [ContextItem],
                        overrides: ContextOverrides,
                        aiLabels: [String: String] = [:]) -> [WorkContext] {
        // 1. bucket items by their effective group. An explicit user assignment wins (and covers
        //    keyless items added by hand); otherwise keyable items auto-cluster by their natural key.
        var buckets: [String: [WorkContext.Ref]] = [:]
        var order: [String] = []                          // preserve first-seen group order
        for it in items {
            let natural = ContextKey.key(it)
            let group: String
            if let g = overrides.group(forKey: ContextKey.itemKey(it)) {
                group = g                                 // user filed THIS item (per-item, wins)
            } else if let n = natural, let g = overrides.group(forKey: n) {
                group = g                                 // a key-level assignment (the whole site/project)
            } else if let n = natural {
                group = n                                 // auto-cluster (keyable only)
            } else {
                continue                                  // keyless + unassigned → not clustered
            }
            if buckets[group] == nil { order.append(group) }
            buckets[group, default: []].append(.init(app: it.app, title: it.title, key: natural ?? ContextKey.itemKey(it)))
        }

        // 2. materialize the groups we want to surface.
        var result: [WorkContext] = []
        for group in order {
            let members = buckets[group]!
            if overrides.isIgnored(group) { continue }                              // user removed this context
            let appCount = Set(members.map { $0.app }).count
            guard appCount >= 2 || overrides.isUserNamed(group) else { continue }   // skip lone-app noise
            let userLabel = overrides.label(forGroup: group)
            let label = userLabel ?? aiLabels[group] ?? ContextKey.displayLabel(group)
            let aiLabeled = userLabel == nil && aiLabels[group] != nil   // AI named it, user hasn't overridden
            result.append(WorkContext(id: group, label: label, aiLabeled: aiLabeled, members: members))
        }

        // 3. rank for a STABLE order: broadest (most apps) first, then alphabetical by label.
        // Deliberately NOT by member count (churns as tabs open/close) and NOT by recency.
        return result.sorted {
            if $0.apps.count != $1.apps.count { return $0.apps.count > $1.apps.count }
            return $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending
        }
    }
}
