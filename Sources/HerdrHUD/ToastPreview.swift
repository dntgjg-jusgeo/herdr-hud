import AppKit

enum ToastPreview {
    static func fitted(_ text: String, font: NSFont, width: CGFloat, height: CGFloat) -> String {
        let clean = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        func fits(_ value: String) -> Bool {
            (value as NSString).boundingRect(with:NSSize(width:width,height:CGFloat.greatestFiniteMagnitude),options:[.usesLineFragmentOrigin,.usesFontLeading],attributes:[.font:font]).height <= height
        }
        if fits(clean) { return clean }
        var words = clean.split(separator:" ").map(String.init)
        while words.count > 1 {
            words.removeLast()
            let candidate = words.joined(separator:" ").trimmingCharacters(in:CharacterSet(charactersIn:",:;…")) + "…"
            if fits(candidate) { return candidate }
        }
        var prefix = String(clean.prefix(150))
        while !prefix.isEmpty && !fits(prefix + "…") { prefix.removeLast() }
        return prefix + "…"
    }
}
