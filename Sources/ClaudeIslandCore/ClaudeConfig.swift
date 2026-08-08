import Foundation

/// Claude Code's own config, read for the one fact its transcripts omit.
///
/// A session running the million-token variant still records the plain id on
/// every assistant line — `claude-opus-5`, never `claude-opus-5[1m]`. Measured
/// across 25 transcripts: not one carried the suffix. It survives in exactly
/// one place, the per-project usage ledger Claude Code writes at session end:
///
///     projects → <cwd> → lastModelUsage → { "claude-opus-5[1m]": { … } }
///
/// So the tier is read from the last session in the same working directory. A
/// project is worked at one context size for long stretches, which makes that
/// a good predictor — and a wrong guess is self-correcting, because usage past
/// 200k promotes the tier on its own.
public enum ClaudeConfig {
    public static var defaultURL: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude.json")
    }

    /// True when `cwd`'s last recorded session ran `model` at the long tier.
    ///
    /// Matched per model, so a project that ran Sonnet at 1M says nothing about
    /// an Opus session in the same directory.
    public static func usesLongContext(model: String?, cwd: String?, url: URL = defaultURL) -> Bool
    {
        guard let model = model?.lowercased(), !model.isEmpty,
            let cwd, !cwd.isEmpty
        else { return false }
        let suffixed = model.hasSuffix("[1m]") ? model : model + "[1m]"
        return ledger(url).models(for: cwd).contains(suffixed)
    }

    // MARK: - Reading

    /// One project's recorded model ids, lowercased.
    struct Ledger: Sendable {
        var byProject: [String: Set<String>] = [:]
        func models(for cwd: String) -> Set<String> { byProject[cwd] ?? [] }
    }

    /// The file is small (~44 KB) but rewritten constantly, so it is cached
    /// against its own mtime rather than re-parsed on every transcript tick.
    private struct Cached {
        let stamp: Date
        let size: Int
        let ledger: Ledger
    }

    nonisolated(unsafe) private static var cache: [String: Cached] = [:]
    private static let lock = NSLock()

    private static func ledger(_ url: URL) -> Ledger {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let stamp = (attrs?[.modificationDate] as? Date) ?? .distantPast
        let size = (attrs?[.size] as? Int) ?? -1

        lock.lock()
        if let hit = cache[url.path], hit.stamp == stamp, hit.size == size {
            lock.unlock()
            return hit.ledger
        }
        lock.unlock()

        let parsed = parse(url)
        lock.lock()
        cache[url.path] = Cached(stamp: stamp, size: size, ledger: parsed)
        lock.unlock()
        return parsed
    }

    private static func parse(_ url: URL) -> Ledger {
        guard let data = try? Data(contentsOf: url),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let projects = root["projects"] as? [String: Any]
        else { return Ledger() }

        var ledger = Ledger()
        for (cwd, value) in projects {
            guard let project = value as? [String: Any],
                let usage = project["lastModelUsage"] as? [String: Any]
            else { continue }
            ledger.byProject[cwd] = Set(usage.keys.map { $0.lowercased() })
        }
        return ledger
    }
}
