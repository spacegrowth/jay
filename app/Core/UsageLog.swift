import Foundation
import Sparkle   // TEMP: force-link Sparkle; sparkle-wiring replaces this (see _SparkleForceLink below)

/// Tiny, **local-only**, private usage log — never leaves the machine. Append-only JSONL
/// in Application Support, size-capped with one rotation. Purpose: after a month of use,
/// answer "how (and how often) do I actually use this" — which trigger, pick-vs-dismiss,
/// what gets picked and its list position (validates MRU), what I search for — so the
/// product can be tuned, or the project retired if it's barely used.
///
/// Inspect:   cat ~/Library/Application\ Support/Jay/usage.jsonl
/// Wipe:      rm   ~/Library/Application\ Support/Jay/usage.jsonl*
final class UsageLog {
    static let shared = UsageLog()
    private let url: URL
    private let q = DispatchQueue(label: "com.jaymac.jay.usagelog")
    private let cap = 2_000_000                     // ~2 MB, then rotate to usage.jsonl.1
    private static let iso = ISO8601DateFormatter()

    private init() {
        let base = (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                    ?? URL(fileURLWithPath: NSTemporaryDirectory()))
            .appendingPathComponent("Jay", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        url = base.appendingPathComponent("usage.jsonl")
    }

    /// Record one event. Extra fields are merged in; `event` and `ts` are always added.
    func log(_ event: String, _ fields: [String: Any] = [:]) {
        var obj = fields
        obj["event"] = event
        obj["ts"] = UsageLog.iso.string(from: Date())
        guard JSONSerialization.isValidJSONObject(obj),
              let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        q.async {
            self.rotateIfNeeded()
            var line = data; line.append(0x0A)                 // newline
            if let h = try? FileHandle(forWritingTo: self.url) {
                defer { try? h.close() }
                h.seekToEndOfFile(); h.write(line)
            } else {
                try? line.write(to: self.url)                   // first write creates the file
            }
        }
    }

    private func rotateIfNeeded() {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int, size > cap else { return }
        let old = url.appendingPathExtension("1")               // usage.jsonl.1 (keep one generation)
        try? FileManager.default.removeItem(at: old)
        try? FileManager.default.moveItem(at: url, to: old)
    }
}

// TEMP: force-link Sparkle so the dynamic linker binds Sparkle.framework and it loads at launch.
// This packet (sparkle-build) only vendors/embeds/signs the framework — it wires up NO update UI.
// The sparkle-wiring packet replaces this with a real SPUStandardUpdaterController instantiation.
// The `@_used`/reference keeps the symbol from being dead-stripped even though nothing calls it.
enum _SparkleForceLink {
    static let type: AnyClass = SPUStandardUpdaterController.self
}
