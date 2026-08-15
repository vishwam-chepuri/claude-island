import Foundation

/// A one-line account of what a session is doing, drawn only on the expanded
/// card.
///
/// Deliberately not on the pill or the peek row. The compact tiers are sized to
/// their text and centred on the camera, so a variable-length prose line there
/// reflows the whole HUD on every tool call; the expanded card already hosts
/// variable-width rows and is sized per shown session.
public struct SessionActivity: Sendable, Equatable {
    /// Which of the two producers wrote this line.
    ///
    /// Worth keeping rather than collapsing to a plain string: the two differ in
    /// both prose quality and freshness, and the precedence rule in
    /// `SessionStore` is the only place that gets to weigh them.
    public enum Source: Sendable, Equatable {
        /// Claude Code's own classifier, read verbatim from its background-job
        /// store. The exact string its agents view shows.
        case jobStore
        /// Derived here from the transcript, mirroring the cheap tier Claude
        /// Code itself falls back to when nothing is paying for a model call.
        case transcript
    }

    public var text: String
    public var source: Source
    public var at: Date

    public init(text: String, source: Source, at: Date) {
        self.text = text
        self.source = source
        self.at = at
    }
}

/// Builds the transcript-derived line.
///
/// This mirrors, in miniature, the ladder Claude Code runs when no surface is
/// paying for its classifier: an explicit end-of-turn marker if the assistant
/// wrote one, else its last prose, else a phrase describing the tool in flight.
/// Reproducing it here is what makes the line appear for ordinary terminal
/// sessions at all — for those, Claude Code computes a line but keeps it in
/// memory and never writes it anywhere an outside observer can read.
public enum ActivityPhrase {
    /// How much of a line is kept. Far past what the card draws on one row; the
    /// surplus is so the string stays readable if the row ever wraps, and so
    /// truncation is the view's decision rather than baked into the model.
    public static let limit = 160

    /// The shortest prose worth preferring over the tool phrase.
    ///
    /// Claude Code uses the same floor. Below it a text block is almost always
    /// a fragment — an acknowledgement, a stray bullet — and the tool actually
    /// running says more about what the session is doing than "OK." does.
    private static let minimumProse = 8

    // MARK: - Assistant prose

    /// The line for a block of assistant text, or nil if it says too little.
    ///
    /// An end-of-turn marker outranks the prose around it: the harness asks
    /// background agents to write `result:` precisely so a machine can lift the
    /// headline without re-reading the turn, and honouring it here means the
    /// card ends a finished session on the same sentence its own job store does.
    public static func fromProse(_ raw: String) -> String? {
        if let marked = marker(in: raw) { return clamp(marked) }
        let collapsed = collapse(raw)
        guard collapsed.count >= minimumProse else { return nil }
        return clamp(collapsed)
    }

    /// The capture of the last `result:` / `needs input:` / `failed:` /
    /// `blocked:` line, if the text ends on one.
    ///
    /// Anchored to line starts so a mention of the convention mid-sentence does
    /// not read as a use of it.
    static func marker(in raw: String) -> String? {
        var found: String?
        for line in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            for key in ["result:", "needs input:", "failed:", "blocked:"]
            where trimmed.lowercased().hasPrefix(key) {
                let body = trimmed.dropFirst(key.count).trimmingCharacters(in: .whitespaces)
                // A bare marker with its text on the next line is not a capture;
                // leaving `found` alone lets the prose path handle it.
                if body.count >= 3 { found = body }
            }
        }
        return found
    }

    // MARK: - Tool phrases

    /// What to show while a tool runs and the assistant has not spoken since.
    ///
    /// Prefers the tool's own `description` — Bash and Task carry one, written
    /// as an imperative — and puts it in the present participle so the row reads
    /// as something in progress rather than an instruction. Everything else
    /// falls back to a phrase built from the same field `ToolActivity` already
    /// extracts for the trail, which keeps the two rows describing one call in
    /// the same words.
    public static func fromTool(name: String, input: JSONValue?) -> String? {
        if let described = input?["description"]?.stringValue, !described.isEmpty {
            return clamp(gerund(collapse(described)))
        }
        // AskUserQuestion's payload is an array of questions; the first one is
        // the thing the session is actually stuck on.
        if let question = input?["questions"]?.arrayValue?.first?["question"]?.stringValue,
            !question.isEmpty
        {
            return clamp(collapse(question))
        }
        let target = ToolActivity.extractTarget(toolName: name, input: input)
        return clamp(phrase(kind: ToolKind(toolName: name), toolName: name, target: target))
    }

    private static func phrase(kind: ToolKind, toolName: String, target: String?) -> String {
        guard let target, !target.isEmpty else { return bareVerb(kind: kind, toolName: toolName) }
        return switch kind {
        case .bash: "Running \(target)"
        case .read: "Reading \(target)"
        case .edit: "Editing \(target)"
        case .write: "Writing \(target)"
        case .notebook: "Editing notebook \(target)"
        case .grep: "Searching for \(target)"
        case .glob: "Finding \(target)"
        case .webFetch: "Fetching \(target)"
        case .webSearch: "Searching the web for \(target)"
        case .task: "Delegating \(target)"
        case .todo, .question: bareVerb(kind: kind, toolName: toolName)
        case .other: "Running \(toolName)"
        }
    }

    private static func bareVerb(kind: ToolKind, toolName: String) -> String {
        switch kind {
        case .todo: "Updating its task list"
        case .question: "Waiting on your answer"
        case .bash: "Running a command"
        case .read: "Reading a file"
        case .edit, .write: "Editing a file"
        case .notebook: "Editing a notebook"
        case .grep, .glob: "Searching the tree"
        case .webFetch, .webSearch: "Reading the web"
        case .task: "Running a subagent"
        case .other: "Running \(toolName)"
        }
    }

    // MARK: - Imperative to participle

    /// "Run the tests" -> "Running the tests".
    ///
    /// Gated on a known verb rather than applied to any leading word. Tool
    /// descriptions are imperative by convention, not by enforcement, and a
    /// wrong guess is conspicuous — a noun-led description would come out as
    /// "Sessioning metadata storage". When the first word is not a verb we
    /// recognise, the description is already readable as written, so it is left
    /// alone.
    static func gerund(_ text: String) -> String {
        let space = text.firstIndex(of: " ") ?? text.endIndex
        let head = String(text[text.startIndex..<space])
        let tail = String(text[space...])
        let key = head.lowercased()
        guard verbs.contains(key) || irregular[key] != nil else { return text }
        let participle = irregular[key] ?? regularGerund(key)
        // Descriptions are sentence-cased; keep whatever case the source used
        // so the row does not shout or whisper differently from its neighbours.
        let cased =
            head.first?.isUppercase == true ? participle.prefix(1).uppercased() + participle.dropFirst()
            : participle
        return cased + tail
    }

    private static func regularGerund(_ verb: String) -> String {
        if verb.hasSuffix("ie") { return String(verb.dropLast(2)) + "ying" }
        if verb.hasSuffix("e"), !verb.hasSuffix("ee"), !verb.hasSuffix("oe"), !verb.hasSuffix("ye") {
            return String(verb.dropLast()) + "ing"
        }
        if verb.hasSuffix("c") { return verb + "king" }
        if shouldDouble(verb), let last = verb.last { return verb + String(last) + "ing" }
        return verb + "ing"
    }

    /// Consonant-vowel-consonant on a single-syllable stem, which English
    /// doubles: "drop" -> "dropping". Approximated by vowel count because the
    /// alternative is a syllable counter, and the irregular table already
    /// carries the multi-syllable doublers ("commit", "prefer") that the
    /// approximation would miss.
    private static func shouldDouble(_ verb: String) -> Bool {
        let vowels = Set("aeiou")
        guard verb.count >= 3, verb.filter({ vowels.contains($0) }).count == 1 else { return false }
        let chars = Array(verb)
        guard let last = chars.last, let middle = chars.dropLast().last,
            let first = chars.dropLast(2).last
        else { return false }
        guard !vowels.contains(last), !"wxy".contains(last) else { return false }
        return vowels.contains(middle) && !vowels.contains(first)
    }

    /// Doublers and drop-outs the rule above cannot derive.
    private static let irregular: [String: String] = [
        "begin": "beginning", "commit": "committing", "control": "controlling",
        "debug": "debugging", "emit": "emitting", "equip": "equipping",
        "forget": "forgetting", "format": "formatting", "input": "inputting",
        "occur": "occurring", "omit": "omitting", "output": "outputting",
        "permit": "permitting", "prefer": "preferring", "quit": "quitting",
        "refer": "referring", "rerun": "rerunning", "reset": "resetting",
        "screenshot": "screenshotting", "snapshot": "snapshotting",
        "submit": "submitting", "sync": "syncing", "transfer": "transferring",
        "unset": "unsetting", "unwrap": "unwrapping", "unzip": "unzipping",
    ]

    /// Verbs that actually open tool descriptions, gathered from this project's
    /// own transcripts. Not a dictionary — a description starting with anything
    /// outside this set is left verbatim, which is the safe failure.
    private static let verbs: Set<String> = [
        "add", "analyze", "apply", "audit", "build", "bump", "cancel", "capture",
        "check", "clean", "clear", "collect", "compare", "compile", "confirm",
        "convert", "copy", "count", "create", "delete", "deploy", "detect",
        "diff", "disable", "drop", "dump", "enable", "ensure", "expand",
        "export", "extract", "fetch", "find", "fix", "generate", "get", "grep",
        "identify", "import", "increment", "index", "insert",
        "inspect", "install", "instrument", "invoke", "kill", "launch", "link",
        "list", "load", "locate", "log", "look", "make", "map", "measure",
        "merge", "migrate", "move", "normalize", "open", "parse", "patch",
        "pin", "poll", "print", "probe", "prune", "publish", "pull", "push",
        "read", "rebase", "rebuild", "record", "reduce", "refresh", "regenerate",
        "reinstall", "remove", "rename", "render", "repair", "replace", "report",
        "resolve", "restart", "restore", "retry", "revert", "review", "rewrite",
        "run", "save", "scan", "search", "seed", "set", "show", "simplify",
        "sort", "split", "stage", "start", "stash", "stop", "store", "summarize",
        "swap", "switch", "sync", "tag", "tail", "test", "trace", "track",
        "trim", "uninstall", "update", "upgrade", "validate", "verify", "walk",
        "watch", "write",
    ]

    // MARK: - Shaping

    /// Whitespace collapse. A transcript's prose carries hard newlines and
    /// markdown indentation, neither of which survives a single-line row.
    static func collapse(_ raw: String) -> String {
        raw.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    /// Redaction then length. Redaction is not optional here even though the
    /// text is prose rather than a command: a session narrating what it just ran
    /// quotes that command, secrets and all.
    static func clamp(_ text: String) -> String? {
        Redactor.sanitize(text, limit: limit)
    }
}
