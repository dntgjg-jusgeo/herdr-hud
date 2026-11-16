import Foundation

/// Links are discovered from the selected terminal's output, never accepted as arbitrary paths from JS.
final class FileLinks {
    struct Entry { let agent: String; let url: URL }
    private var entries: [String: Entry] = [:]
    static let images: Set<String> = ["png","jpg","jpeg","gif","webp","tiff","heic","pdf"]
    static let documents: Set<String> = ["docx","xlsx","pptx","odt","ods","odp"]
    static let text: Set<String> = ["txt","md","markdown","json","jsonl","csv","tsv","log","swift","rs","py","js","jsx","ts","tsx","html","css","scss","toml","yaml","yml","xml","sql","sh","zsh","c","h","cpp","hpp","go","java","kt","rb","php","vue","svelte"]
    static var extensions: Set<String> { images.union(documents).union(text) }
    func discover(agent: String, output: String, directory: String) -> [Row] {
        let previous = entries.filter { $0.value.agent == agent }
        entries = entries.filter { $0.value.agent != agent }
        guard directory.hasPrefix("/") else { return [] }
        var candidates: [String] = []
        // Markdown targets support spaces; literal absolute paths and code spans cover CLI output.
        for pattern in [#"\]\((?:<)?([^\n<>]+?)(?:>)?\)"#, #"`([^`\n]+)`"#, #"(?:^|[\s(])((?:/|\./|outputs/)[^\n]+)"#] {
            guard let regex = try? NSRegularExpression(pattern:pattern,options:[.anchorsMatchLines]) else { continue }
            let bounded = String(output.suffix(100_000))
            for match in regex.matches(in:bounded,range:NSRange(bounded.startIndex...,in:bounded)).prefix(200) {
                if let range = Range(match.range(at:1),in:bounded) { candidates.append(String(bounded[range])) }
            }
        }
        var seen = Set<String>(), result: [Row] = []
        for candidate in candidates {
            guard candidate.utf8.count <= 4096 else { continue }
            var value = candidate.trimmingCharacters(in:.whitespacesAndNewlines)
            if value.hasPrefix("file://"), let url = URL(string:value), url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost" { value = url.path }
            else if value.contains("://") { continue }
            // Strip editor line suffixes; never run a URL scheme or terminal command.
            value = value.replacingOccurrences(of:#":\d+(?::\d+)?$"#,with:"",options:.regularExpression)
            let words = value.split(separator:" ").prefix(40)
            let variants = [value] + words.indices.map { i in words.prefix(i+1).joined(separator:" ") }.reversed()
            for raw in variants {
                let trimmed = raw.trimmingCharacters(in:CharacterSet(charactersIn:"\"'.,;:)"))
                let url = (trimmed.hasPrefix("/") ? URL(fileURLWithPath:trimmed) : URL(fileURLWithPath:directory).appendingPathComponent(trimmed)).standardizedFileURL
                guard Self.extensions.contains(url.pathExtension.lowercased()), !seen.contains(url.path), Self.valid(url) else { continue }
                seen.insert(url.path);let token=previous.first(where: { $0.value.url == url })?.key ?? UUID().uuidString;entries[token]=Entry(agent:agent,url:url)
                result.append(["token":token,"name":url.lastPathComponent,"path":url.path,"kind":Self.images.contains(url.pathExtension.lowercased()) ? "Preview" : "Open"])
                break
            }
            if result.count == 20 { break }
        }
        if entries.count > 200 { entries = entries.filter { $0.value.agent == agent } }
        return result
    }
    static func valid(_ url: URL) -> Bool {
        guard url.isFileURL, url.path == url.resolvingSymlinksInPath().path,
              let facts = try? url.resourceValues(forKeys:[.isRegularFileKey,.volumeIsLocalKey]),
              facts.isRegularFile == true, facts.volumeIsLocal == true else { return false }
        return true
    }
    func resolve(agent: String, token: String) throws -> URL {
        guard let entry=entries[token],entry.agent==agent,Self.valid(entry.url) else { throw HUDError("This file link changed or expired. Refresh the reply and try again.") }
        return entry.url
    }
}
