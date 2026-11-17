import Darwin
import Foundation

/// A view of the terminal's own model menu. Keys come from the recognized stage
/// and displayed rows, never from a model name or WebView-supplied command.
struct ModelPicker {
    struct Choice {
        let key: String
        let label: String
        let detail: String
        let selected: Bool

        var focusKey: String { "focus:"+key }
        var row: Row { ["key":focusKey, "label":label, "selected":selected] }
    }

    let heading: String
    let text: String
    let applyKey: String?
    let selectedChoice: Choice
    let choices: [Choice]

    private static let codexHeadings = ["Select Model and Effort", "Select Model"]
    private static let codexReasoning = "Select Reasoning Level for "
    private static let claudeHeading = "Select model"
    private static let advancedReasoning = "Advanced Reasoning"
    private static let codexContinue = "enter select · esc back"
    private static let codexSessionFooters = ["enter default · s session · esc back", "enter apply · s session · esc back"]
    private static let numbered = try! NSRegularExpression(pattern:#"^([›❯>])?\s*([1-9][0-9]*)\.\s+(.+)$"#)

    static func lines(_ screen: String) -> [String] {
        screen.components(separatedBy:.newlines)
            .map { $0.trimmingCharacters(in:.whitespaces) }
            .filter { !$0.isEmpty }
    }

    static func menu(_ screen: String, provider: String) -> Self? {
        let lines = lines(screen)
        guard let footer = lines.last else { return nil }
        let isHeading: (String) -> Bool = provider == "codex"
            ? { codexHeadings.contains($0) || $0.hasPrefix(codexReasoning) || $0 == advancedReasoning }
            : { $0 == claudeHeading }
        guard let start = lines.lastIndex(where:isHeading), start < lines.count-1 else { return nil }
        let heading = lines[start]
        let entries = lines[(start+1)..<(lines.count-1)].compactMap { line -> Choice? in
            guard let match = numbered.firstMatch(in:line,range:NSRange(line.startIndex...,in:line)),
                  let number = Range(match.range(at:2),in:line), let content = Range(match.range(at:3),in:line) else { return nil }
            let body = String(line[content])
            let gap = body.range(of:#"\s{2,}"#,options:.regularExpression)
            return Choice(key:String(line[number]), label:gap.map { String(body[..<$0.lowerBound]) } ?? body,
                          detail:gap.map { String(body[$0.upperBound...]) } ?? "", selected:match.range(at:1).location != NSNotFound)
        }
        let selected = entries.filter(\.selected)
        guard !entries.isEmpty, Set(entries.map(\.key)).count == entries.count, selected.count == 1 else { return nil }

        let applyKey: String?
        var choices: [Choice] = []
        let selection = selected[0]
        if provider == "codex", codexHeadings.contains(heading),
           footer == codexContinue || codexSessionFooters.contains(footer) {
            choices = entries.filter { isCodexModel($0.label) || $0.label == "All models (current)" || $0.label == "All models" }
            if choices.contains(where:{ $0.key == selection.key }) {
                applyKey = footer == codexContinue ? "enter" : "s"
            } else { applyKey = nil }
        } else if provider == "codex", heading.hasPrefix(codexReasoning),
                  isCodexModel(String(heading.dropFirst(codexReasoning.count))) {
            if selection.label.hasPrefix("More reasoning"), footer == codexContinue { applyKey = "enter" }
            else {
                let effort = selection.label.components(separatedBy:" (").first ?? ""
                guard codexSessionFooters.contains(footer) else { return nil }
                applyKey = ["None","Minimal","Low","Medium","High","Extra high"].contains(effort) ? "s" : nil
            }
        } else if provider == "codex", heading == advancedReasoning, codexSessionFooters.contains(footer),
                  lines[(start+1)..<(lines.count-1)].contains("⚠ Consumes usage limits faster") {
            let effort = selection.label.components(separatedBy:" (").first ?? ""
            applyKey = ["Max","Ultra"].contains(effort) ? "s" : nil
        } else if provider == "claude", heading == claudeHeading,
                  footer == "Enter to set as default · s to use this session only · Esc to cancel",
                  lines[(start+1)..<(lines.count-1)].contains(where:{ $0.hasPrefix("Switch between Claude models.") }) {
            choices = entries.filter(isClaudeModel)
            applyKey = choices.contains(where:{ $0.key == selection.key }) ? "s" : nil
        } else { return nil }
        return Self(heading:heading, text:lines[start...].joined(separator:"\n"), applyKey:applyKey, selectedChoice:selection, choices:choices)
    }

    private static let claudeFamilies = ["Opus","Sonnet","Haiku","Fable"]
    private static func isClaudeModel(_ choice: Choice) -> Bool {
        if choice.label.hasPrefix("Default (recommended)") {
            guard choice.detail.contains("currently ") else { return false }
            let family = choice.detail.components(separatedBy:"currently ").last?.components(separatedBy:" ").first
            return family.map(claudeFamilies.contains) == true
        }
        return claudeFamilies.contains(choice.label) && choice.detail.hasPrefix(choice.label+" ")
    }

    private static func isCodexModel(_ label: String) -> Bool {
        label.hasPrefix("GPT-") || label.hasPrefix("gpt-")
    }

    static func blankComposer(_ screen: String, provider: String) -> Bool {
        let lines = lines(screen)
        if provider == "codex" {
            guard let composer = lines.lastIndex(where:{ $0.hasPrefix("›") }),
                  lines[composer] == "› Ask Codex to do anything" else { return false }
            let footer = lines[(composer+1)...]
            return !footer.isEmpty && footer.count <= 3
                && footer.contains(where:{ $0.contains("? for shortcuts") || $0.range(of:#"^(GPT-|gpt-)"#,options:.regularExpression) != nil })
        }
        guard provider == "claude", let composer = lines.lastIndex(where:{ $0.hasPrefix("❯") }),
              lines[composer] == "❯", composer > 0,
              composer+1 < lines.count, divider(lines[composer-1]), divider(lines[composer+1]) else { return false }
        return true
    }

    static func stagedCommand(_ screen: String, provider: String) -> Bool {
        let lines = lines(screen)
        if provider == "codex" {
            guard let composer = lines.lastIndex(where:{ $0.hasPrefix("›") }), composer > 0 else { return false }
            return lines[composer] == "› /model"
                && lines[composer-1] == "› /model  choose what model and reasoning effort to use"
        }
        guard provider == "claude", let composer = lines.lastIndex(where:{ $0.hasPrefix("❯") }),
              lines[composer].replacingOccurrences(of:"\u{a0}",with:" ") == "❯ /model",
              composer > 0, composer+1 < lines.count,
              divider(lines[composer-1]), divider(lines[composer+1]) else { return false }
        return lines[..<composer].suffix(12).contains { $0.hasPrefix("❯ /model ") && $0.contains("Set the AI model for Claude Code") }
    }

    private static func divider(_ line: String) -> Bool {
        line.count >= 12 && line.allSatisfy { $0 == "─" }
    }

    /// Inspect only process-local routing overrides. The executable name alone is
    /// also used by wrappers such as orca-claude. Never return or log process data.
    static func allowsClaudeProcess(_ pid: Int32) -> Bool {
        guard pid > 1 else { return false }
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0,
              size > MemoryLayout<Int32>.size, size <= 4 * 1024 * 1024 else { return false }
        var bytes = [UInt8](repeating:0,count:size)
        guard sysctl(&mib, UInt32(mib.count), &bytes, &size, nil, 0) == 0,
              size > MemoryLayout<Int32>.size, size <= bytes.count else { return false }
        return bytes.withUnsafeBytes { raw in
            let argc = Int(raw.loadUnaligned(as:Int32.self))
            guard argc > 0 else { return false }
            var index = MemoryLayout<Int32>.size
            guard let end = bytes[index..<size].firstIndex(of:0) else { return false }
            index = end
            while index < size && bytes[index] == 0 { index += 1 }
            for _ in 0..<argc {
                guard let end = bytes[index..<size].firstIndex(of:0) else { return false }
                index = end+1
            }
            return allowsClaudeEnvironment(bytes[index..<size])
        }
    }

    static func allowsClaudeEnvironment(_ environment: ArraySlice<UInt8>) -> Bool {
        let base = Array("ANTHROPIC_BASE_URL=".utf8)
        let model = Array("ANTHROPIC_MODEL=".utf8)
        let providerFlags = ["CLAUDE_CODE_USE_BEDROCK=", "CLAUDE_CODE_USE_VERTEX=", "CLAUDE_CODE_USE_FOUNDRY="].map { Array($0.utf8) }
        let overrides = ["ANTHROPIC_DEFAULT_OPUS_MODEL=", "ANTHROPIC_DEFAULT_SONNET_MODEL=", "ANTHROPIC_DEFAULT_HAIKU_MODEL=", "ANTHROPIC_DEFAULT_FABLE_MODEL="].map { Array($0.utf8) }
        let entries = environment.split(separator:0)
        guard entries.contains(where:{ $0.contains(61) }) else { return false }
        let modelKeys = [model]+overrides
        let aliases = claudeFamilies.map { $0.lowercased() }
        for entry in entries {
            if entry.starts(with:base), !entry.dropFirst(base.count).isEmpty,
               !["https://api.anthropic.com","https://api.anthropic.com/"].contains(String(decoding:entry.dropFirst(base.count),as:UTF8.self)) { return false }
            if let flag = providerFlags.first(where:{ entry.starts(with:$0) }),
               !["","0","false"].contains(String(decoding:entry.dropFirst(flag.count),as:UTF8.self).lowercased()) { return false }
            if let key = modelKeys.first(where:{ entry.starts(with:$0) }) {
                let value = String(decoding:entry.dropFirst(key.count),as:UTF8.self)
                guard value.isEmpty || value.hasPrefix("claude-") || aliases.contains(value) else { return false }
            }
        }
        return true
    }
}
