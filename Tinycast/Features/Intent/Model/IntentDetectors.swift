import Foundation

/// A phrase that reads as "remind/notify me" — reminder intent before any time is even typed.
struct ReminderIntentDetector: IntentDetector {
    let intent = QueryIntent.reminder

    func score(_ query: QueryText) -> Double {
        query.containsAny(of: Self.markers) ? 1 : 0
    }

    static let markers = [
        "remind", "reminder", "notify me", "notification", "alert me",
        "ping me", "wake me", "nudge me", "don't let me forget", "dont let me forget",
    ]
}

/// A shell invocation: a known command word up front, a leading path, or a shell operator. Kept
/// deliberately strict — running arbitrary typed text is the one fallback where a false match bites.
struct ShellCommandIntentDetector: IntentDetector {
    let intent = QueryIntent.shellCommand

    func score(_ query: QueryText) -> Double {
        if query.containsAny(of: Self.operators) { return 1 }
        let head = query.firstWord
        if head == "sudo" { return 1 }
        if Self.commands.contains(String(head)) { return 0.9 }
        if head.hasPrefix("./") || head.hasPrefix("/") || head.hasPrefix("~/") { return 0.7 }
        return 0
    }

    static let operators = [" | ", " && ", " || ", " > ", " >> ", ";", "$(", "`"]

    /// Clearly-technical binaries only; English-verb-like words (find, open, kill) are left out so a
    /// natural phrase is never promoted into an accidental shell run.
    static let commands: Set<String> = [
        "ls", "cd", "cat", "grep", "echo", "cp", "mv", "rm", "mkdir", "touch", "chmod", "chown",
        "git", "brew", "npm", "npx", "yarn", "pnpm", "node", "deno", "bun", "python", "python3",
        "pip", "pip3", "ruby", "go", "cargo", "rustc", "swift", "make", "cmake", "curl", "wget",
        "ssh", "scp", "rsync", "tar", "zip", "unzip", "docker", "kubectl", "helm", "awk", "sed",
        "defaults", "pbcopy", "pbpaste", "xcodebuild", "xcrun", "pod",
    ]
}

/// A file lookup: search verbs paired with "file(s)", or a bare filename with an extension or glob.
struct FileSearchIntentDetector: IntentDetector {
    let intent = QueryIntent.fileSearch

    func score(_ query: QueryText) -> Double {
        if query.containsAny(of: Self.phrases) { return 0.8 }
        if Self.looksLikeFilename(query) { return 0.7 }
        return 0
    }

    static let phrases = [
        "search files", "search file", "search for files", "find files", "find file",
        "file named", "files named", "locate file", "open file", "find the file",
    ]

    /// One token that ends in a short alphabetic extension (`report.pdf`) or opens a glob (`*.png`).
    static func looksLikeFilename(_ query: QueryText) -> Bool {
        guard query.words.count == 1 else { return false }
        let word = query.firstWord
        if word.hasPrefix("*.") { return true }
        guard let dot = word.lastIndex(of: "."), dot != word.startIndex else { return false }
        let ext = word[word.index(after: dot)...]
        return (1...5).contains(ext.count) && ext.allSatisfy(\.isLetter)
    }
}

/// A natural-language question or instruction for the assistant. The broad catch, so it scores below
/// the specific detectors and only fires when the phrase clearly opens as a question or a request.
struct AIQuestionIntentDetector: IntentDetector {
    let intent = QueryIntent.aiQuestion

    func score(_ query: QueryText) -> Double {
        if query.trimmed.hasSuffix("?") { return 0.7 }
        if query.words.count >= 3 && Self.openers.contains(String(query.firstWord)) { return 0.6 }
        return 0
    }

    static let openers: Set<String> = [
        "what", "why", "how", "who", "when", "where", "which", "whose",
        "is", "are", "can", "could", "should", "would", "will", "does", "do", "did",
        "explain", "write", "summarize", "summarise", "translate", "define", "generate",
        "draft", "tell", "describe", "compare", "suggest", "recommend",
    ]
}
