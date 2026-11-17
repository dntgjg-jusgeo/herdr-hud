import Foundation
import CoreFoundation

enum MarkdownAttachment {
    static let maximumBytes = 16 * 1024
    static func validate(_ value: Row) throws -> Row {
        func invalid() -> HUDError { HUDError("Invalid Markdown attachment.") }
        guard value["kind"] as? String == "markdown", let name = value["name"] as? String,
              !name.isEmpty, name.utf16.count <= 120, !name.contains("/"), !name.contains("\\"),
              name != ".", name != "..", name.rangeOfCharacter(from: .controlCharacters) == nil,
              ["md", "markdown"].contains((name as NSString).pathExtension.lowercased()),
              let text = value["text"] as? String, !text.contains("\0"),
              let bytes = value["bytes"] as? NSNumber, CFGetTypeID(bytes) != CFBooleanGetTypeID(),
              bytes.doubleValue == Double(text.utf8.count), text.utf8.count <= maximumBytes else { throw invalid() }
        return ["kind":"markdown", "name":name, "text":text, "bytes":text.utf8.count]
    }
}
