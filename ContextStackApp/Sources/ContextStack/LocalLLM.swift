import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// The on-device LLM tier, via Apple's FoundationModels (macOS 26 +
/// Apple Intelligence). Everything is canImport/availability-guarded:
/// on machines without the framework or with Apple Intelligence off, all
/// entry points report unavailable and the features hide themselves.
///
/// Uses: condensing a multi-select stack before pasting, and background
/// tagging of archived captures (contentLearning opt-in) so future ranking
/// tiers get content-type features. Fully local — nothing leaves the Mac.
enum LocalLLM {
    static var availabilityNote: String {
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *) else {
            return "unavailable: needs macOS 26"
        }
        switch SystemLanguageModel.default.availability {
        case .available:
            return "available"
        case .unavailable(let reason):
            return "unavailable: \(reason)"
        }
        #else
        return "unavailable: FoundationModels framework not present"
        #endif
    }

    static var isAvailable: Bool {
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *) else { return false }
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
        #else
        return false
        #endif
    }

    /// One prompt → one response; completion on main. Nil on any failure —
    /// callers must have a non-LLM fallback.
    static func respond(instructions: String, prompt: String,
                        completion: @escaping (String?) -> Void) {
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *), isAvailable else {
            DispatchQueue.main.async { completion(nil) }
            return
        }
        Task {
            do {
                let session = LanguageModelSession(instructions: instructions)
                let response = try await session.respond(to: prompt)
                let content = response.content
                DispatchQueue.main.async { completion(content) }
            } catch {
                csLog("LLM request failed:", error.localizedDescription)
                DispatchQueue.main.async { completion(nil) }
            }
        }
        #else
        DispatchQueue.main.async { completion(nil) }
        #endif
    }

    // ------------------------------------------------------------ summarize

    /// Condense a combined context stack; keeps code/error lines verbatim
    /// where they matter. Nil → caller pastes the raw stack.
    static func summarizeStack(_ stack: String,
                               completion: @escaping (String?) -> Void) {
        let capped = String(stack.prefix(24_000))
        respond(
            instructions: """
            You condense multi-source working context for a developer who is
            about to paste it into an AI chat. Keep exact identifiers, paths,
            error messages and short code fragments verbatim. Drop
            repetition and boilerplate. Structure: one short section per
            source, matching the input's numbered sections. Be dense.
            """,
            prompt: "Condense this context stack to its essentials "
                + "(target: under 400 words):\n\n\(capped)",
            completion: completion)
    }

    // -------------------------------------------------------------- tagging

    static let tagVocabulary = ["code", "error-log", "docs", "prose",
                                "data", "config", "chat", "terminal-output"]

    /// Background content-type tagging of an archived capture. Gated on the
    /// contentLearning opt-in by the caller. Tags land in
    /// capture-tags.jsonl next to the other learning logs.
    static func tagCapture(file: URL, text: String) {
        guard Config.contentLearning, isAvailable else { return }
        let snippet = String(text.prefix(4_000))
        let vocab = tagVocabulary.joined(separator: ", ")
        respond(
            instructions: """
            You are a strict classifier. You may only ever answer with tags
            from this closed list: \(vocab). Never invent other words.
            """,
            prompt: """
            Text:
            \(snippet)

            Pick 1–3 tags for the text above, ONLY from: \(vocab)
            Answer with just the tags, comma-separated. Tags:
            """) { reply in
            guard let reply else { return }
            let tags = reply.lowercased()
                .components(separatedBy: CharacterSet(charactersIn: ",\n"))
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { tagVocabulary.contains($0) }
            guard !tags.isEmpty else { return }
            struct TagEvent: Codable {
                let ts: Double
                let file: String
                let tags: [String]
            }
            EventLogFile(filename: "capture-tags.jsonl")
                .append(TagEvent(ts: Date().timeIntervalSince1970,
                                 file: file.lastPathComponent, tags: tags))
            csLog("tagged \(file.lastPathComponent): \(tags.joined(separator: ","))")
        }
    }
}
