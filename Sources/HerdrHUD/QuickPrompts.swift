import Foundation

enum QuickPrompts {
    static let defaults: [Row] = [
        ["label":"Review this","text":"Please review the current changes and flag any issues."],
        ["label":"Run tests","text":"Please run the relevant tests and report the results."],
        ["label":"Summarize progress","text":"Please summarize what is done, what remains, and any blockers."]
    ]
    static func validate(_ value: Any?) throws -> [Row] {
        guard let rows=value as? [Row],rows.count<=6 else { throw HUDError("Use up to six quick prompts.") }
        return try rows.map { row in
            guard let label=row["label"] as? String,let text=row["text"] as? String,
                  !label.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,label.count<=32,
                  !text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,text.count<=2000 else { throw HUDError("Each quick prompt needs a short name and text under 2,000 characters.") }
            return ["label":label,"text":text]
        }
    }
}
