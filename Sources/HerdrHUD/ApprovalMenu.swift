import Foundation

/// Recognizes displayed numbered menu entries, not their effective keybindings.
/// The HUD exposes literal digit keys, never a semantic approval promise.
struct ApprovalMenu {
    static let labels=["Allow","Allow for this session","Always allow","Cancel"]
    static func choices(_ text: String) -> [Row]? {
        let lines=text.components(separatedBy:.newlines).map { $0.trimmingCharacters(in:.whitespaces) }
        guard let field=lines.lastIndex(of:"Field 1/1"),
              let question=lines[(field+1)...].firstIndex(where: { $0.hasPrefix("Allow Computer Use to use ") }),
              let footer=lines.lastIndex(where: { $0.lowercased()=="enter to submit | esc to cancel" }), question<footer,
              lines[(footer+1)...].allSatisfy({ $0.isEmpty }) else { return nil }
        let regex=try! NSRegularExpression(pattern:#"^([›❯>])?\s*([1-4])\.\s+(.+?)\s*$"#)
        var found:[Row]=[],selected=0
        for line in lines[(question+1)..<footer] {
            guard let match=regex.firstMatch(in:line,range:NSRange(line.startIndex...,in:line)),let nr=Range(match.range(at:2),in:line),let rest=Range(match.range(at:3),in:line) else { continue }
            let number=Int(line[nr])!,body=String(line[rest]),label=labels[number-1]
            guard number==found.count+1,body==label||body.hasPrefix(label+"  ") else { return nil }
            if match.range(at:1).location != NSNotFound { selected += 1 }
            found.append(["key":String(number),"label":label])
        }
        return found.count==4&&selected==1 ? found : nil
    }
}
