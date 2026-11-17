import Foundation
import CoreFoundation
import Darwin

enum MarkdownAttachment {
    static let maximumBytes = 16 * 1024
    static func importFile(_ url:URL) throws -> Row {
        func refused()->HUDError {HUDError("Use a readable UTF-8 Markdown file up to 16 KB. Your draft is retained.")}
        guard url.isFileURL,url.host == nil || url.host == "" || url.host == "localhost",["md","markdown"].contains(url.pathExtension.lowercased()) else{throw refused()}
        let fd=open(url.path,O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC);guard fd>=0 else{throw refused()};defer{close(fd)}
        var before=stat();guard fstat(fd,&before)==0,before.st_mode&S_IFMT == S_IFREG,before.st_size>=0,before.st_size<=maximumBytes else{throw refused()}
        var data=Data(),buffer=[UInt8](repeating:0,count:4096)
        while true {
            let n=read(fd,&buffer,buffer.count);if n<0 && errno==EINTR{continue}
            guard n>=0,data.count+n<=maximumBytes else{throw refused()};if n==0{break};data.append(contentsOf:buffer.prefix(n))
        }
        var after=stat();guard fstat(fd,&after)==0,after.st_size==before.st_size,data.count==before.st_size,
              after.st_mtimespec.tv_sec==before.st_mtimespec.tv_sec,after.st_mtimespec.tv_nsec==before.st_mtimespec.tv_nsec,
              after.st_ctimespec.tv_sec==before.st_ctimespec.tv_sec,after.st_ctimespec.tv_nsec==before.st_ctimespec.tv_nsec,
              let text=String(data:data,encoding:.utf8) else{throw refused()}
        return try validate(["kind":"markdown","name":url.lastPathComponent,"text":text,"bytes":data.count])
    }
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
