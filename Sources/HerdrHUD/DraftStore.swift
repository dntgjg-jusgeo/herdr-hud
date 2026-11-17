import Foundation
import Darwin
import CoreFoundation

/// Private, bounded snapshots. Call on one serial queue; loading must precede saving.
/// Invalid existing files are left untouched and disable writes for this instance.
final class DraftStore {
    static let maximumDrafts = 128
    static let maximumTextBytes = 60_000
    static let maximumTotalTextBytes = 1024 * 1024
    static let maximumImageBytes = 24 * 1024 * 1024
    static let maximumFileBytes = 36 * 1024 * 1024
    static let maximumQueuePerSession = 16
    static let maximumQueueCount = 128
    static let maximumPosterBytes = 2 * 1024 * 1024
    let directory: URL
    private var loaded = false

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0]
            .appendingPathComponent("Herdr HUD/Drafts",isDirectory:true)
    }
    private func failure() -> HUDError { HUDError("Draft storage unavailable. Existing drafts have been retained; do not restart until your current draft is copied safely.") }
    private func directoryFD() throws -> Int32 {
        // Walk directory descriptors so symlinked or replaced parent components
        // cannot redirect private draft writes to another location.
        guard directory.path.hasPrefix("/") else { throw failure() }
        var fd = open("/",O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw failure() }
        // Foundation standardizedFileURL rewrites existing /private/tmp to the
        // symlink /tmp; retain the caller's physical spelling during this walk.
        for component in directory.pathComponents where component != "/" {
            guard component != ".", component != ".." else { close(fd);throw failure() }
            var next = openat(fd,component,O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if next < 0 && errno == ENOENT {
                guard mkdirat(fd,component,0o700) == 0 || errno == EEXIST else { close(fd);throw failure() }
                next = openat(fd,component,O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            close(fd)
            guard next >= 0 else { throw failure() };fd = next
        }
        var info = stat()
        guard fstat(fd,&info) == 0, info.st_uid == getuid(), fchmod(fd,0o700) == 0 else { close(fd);throw failure() }
        return fd
    }
    static func validate(_ value: Any) throws -> Row {
        func invalid() -> HUDError { HUDError("Draft snapshot is invalid or exceeds its storage limit. Existing drafts and queued prompts have been retained.") }
        guard let snapshot = value as? Row, let version = snapshot["version"] as? NSNumber, CFGetTypeID(version) != CFBooleanGetTypeID(), [1.0,2.0,3.0,4.0,5.0,6.0,7.0].contains(version.doubleValue),
              let rows = snapshot["drafts"] as? [Row], rows.count <= maximumDrafts else { throw invalid() }
        var result:[Row] = [], ids = Set<String>(), tokens = Set<String>(), totalText = 0, totalImages = 0, queueCount = 0, hasVideo=false, hasMarkdown=false, hasPDF=false, hasWord=false, hasFiles=false,files:[String:Row]=[:],totalFiles=0
        var videos:[String:Row]=[:],totalVideos=0,totalPosters=0,pdfs:[String:Row]=[:],totalPDFs=0,words:[String:Row]=[:],totalWords=0
        func parsedImages(_ images: [Row]) throws -> [Row] {
            var safeImages:[Row] = []
            for original in images {
                if original["kind"] as? String == "raster" || (original["kind"] as? String == "markdown" && original["token"] != nil) {
                    guard version.doubleValue>=7 else{throw invalid()}
                    let safe=try FileAttachments.validateReference(original),token=safe["token"] as! String
                    if let prior=files[token]{guard NSDictionary(dictionary:prior).isEqual(to:safe) else{throw invalid()}}else{files[token]=safe;totalFiles+=safe["bytes"] as! Int}
                    guard files.count<=FileAttachments.maximumAssets,totalFiles<=FileAttachments.maximumCacheBytes else{throw invalid()}
                    totalPosters += (safe["poster"] as? String ?? "").utf8.count
                    guard totalPosters<=maximumPosterBytes else{throw invalid()}
                    hasFiles=true;safeImages.append(safe);continue
                }
                if original["kind"] as? String == "word" {
                    guard version.doubleValue>=6 else{throw invalid()}
                    let safe=try WordAttachments.validateReference(original),token=safe["token"] as! String
                    if let prior=words[token] {guard NSDictionary(dictionary:prior).isEqual(to:safe) else{throw invalid()}}
                    else{words[token]=safe;totalWords+=safe["bytes"] as! Int}
                    guard words.count<=128,totalWords<=WordAttachments.maximumCacheBytes else{throw invalid()}
                    hasWord=true;safeImages.append(safe);continue
                }
                if original["kind"] as? String == "pdf" {
                    guard version.doubleValue>=5 else{throw invalid()}
                    let safe=try PDFAttachments.validateReference(original),token=safe["token"] as! String
                    if let prior=pdfs[token] {guard NSDictionary(dictionary:prior).isEqual(to:safe) else{throw invalid()}}
                    else{pdfs[token]=safe;totalPDFs+=safe["bytes"] as! Int}
                    guard pdfs.count<=128,totalPDFs<=PDFAttachments.maximumCacheBytes else{throw invalid()}
                    hasPDF=true;safeImages.append(safe);continue
                }
                if original["kind"] as? String == "video" {
                    guard version.doubleValue>=3 else{throw invalid()}
                    let safe=try VideoAttachments.validateReference(original),token=safe["token"] as! String
                    totalPosters+=(safe["poster"] as! String).utf8.count
                    guard totalPosters<=maximumPosterBytes else{throw invalid()}
                    if let previous=videos[token] {guard NSDictionary(dictionary:previous).isEqual(to:safe) else{throw invalid()}}
                    else {videos[token]=safe;totalVideos+=safe["bytes"] as! Int}
                    guard totalVideos<=VideoAttachments.maximumCacheBytes,videos.count<=VideoAttachments.maximumAssets else{throw invalid()}
                    hasVideo=true;safeImages.append(safe);continue
                }
                if original["kind"] as? String == "markdown" {
                    guard version.doubleValue >= 4 else { throw invalid() }
                    let safe = try MarkdownAttachment.validate(original)
                    totalText += (safe["text"] as! String).utf8.count
                    guard totalText <= maximumTotalTextBytes else { throw invalid() }
                    hasMarkdown = true; safeImages.append(safe); continue
                }
                guard original["kind"] == nil || original["kind"] as? String == "image",let image=try ImageAttachment.parse([original]).first else{throw invalid()}
                totalImages += image.data.count
                guard totalImages <= maximumImageBytes, let name = original["name"] as? String,
                      !name.isEmpty, name.utf8.count <= 480, !name.contains("\0"), !name.contains("/"), !name.contains("\\") else { throw invalid() }
                safeImages.append(["data":image.data.base64EncodedString(),"name":name])
            }
            return safeImages
        }
        for row in rows {
            guard let id = row["id"] as? String, !id.isEmpty, id.utf8.count <= 8192, !id.contains("\0"), ids.insert(id).inserted,
                  let text = row["text"] as? String, text.utf8.count <= maximumTextBytes,
                  let images = row["images"] as? [Row], images.count <= ImageAttachment.maximumCount,
                  let uncertain = row["uncertain"] as? Bool, let keyUncertain = row["keyUncertain"] as? Bool else { throw invalid() }
            totalText += text.utf8.count
            guard totalText <= maximumTotalTextBytes else { throw invalid() }
            let label = row["label"] as? String ?? "Recovered draft"
            guard label.utf8.count <= 800, label.count <= 200 else { throw invalid() }
            let safeImages = try parsedImages(images)
            var queue:[Row] = []
            let rawQueue: [Row]
            if let value = row["queue"] { guard let items = value as? [Row] else { throw invalid() };rawQueue = items } else { rawQueue = [] }
            guard rawQueue.count <= maximumQueuePerSession else { throw invalid() }
            for item in rawQueue {
                guard let token = item["token"] as? String, !token.isEmpty, token.utf8.count <= 128,
                      token.rangeOfCharacter(from:.controlCharacters) == nil, tokens.insert(token).inserted,
                      let queuedText = item["text"] as? String, queuedText.utf8.count <= maximumTextBytes, !queuedText.contains("\0"),
                      let queuedImages = item["images"] as? [Row], queuedImages.count <= ImageAttachment.maximumCount,
                      let status = item["status"] as? String, ["queued","pending","uncertain"].contains(status),
                      !queuedText.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || !queuedImages.isEmpty else { throw invalid() }
                queueCount += 1;totalText += queuedText.utf8.count
                guard queueCount <= maximumQueueCount, totalText <= maximumTotalTextBytes else { throw invalid() }
                queue.append(["token":token,"text":queuedText,"images":try parsedImages(queuedImages),"status":status == "pending" ? "uncertain" : status])
            }
            if !text.isEmpty || !safeImages.isEmpty || uncertain || keyUncertain || !queue.isEmpty {
                var normalized:Row = ["id":id,"label":label,"text":text,"images":safeImages,"uncertain":uncertain,"keyUncertain":keyUncertain]
                if !queue.isEmpty { normalized["queue"] = queue };result.append(normalized)
            }
        }
        return ["version":hasFiles ? 7 : hasWord ? 6 : hasPDF ? 5 : (hasMarkdown ? 4 : (hasVideo ? 3:2)),"drafts":result]
    }
    /// Background delivery is authorized only by the exact persisted FIFO head.
    /// The caller also consumes this token once per app incarnation before IO.
    static func authorizeQueuedPrompt(_ snapshot: Row, id: String, token: String, text: String, attachments: Any?) throws {
        func refused() -> HUDError { HUDError("Queued prompt changed or was not saved for this exact session. Refresh before sending.") }
        let validated = try validate(snapshot)
        guard let rows = validated["drafts"] as? [Row], let row = rows.first(where: { $0["id"] as? String == id }),
              let queue = row["queue"] as? [Row], let head = queue.first,
              head["token"] as? String == token, head["status"] as? String == "uncertain", head["text"] as? String == text,
              let expected = head["images"] as? [Row] else { throw refused() }
        let supplied: [Row]
        if let attachments = attachments { guard let images = attachments as? [Row] else { throw refused() };supplied = images } else { supplied = [] }
        guard supplied.count == expected.count else { throw refused() }
        for (image,saved) in zip(supplied,expected) {
            if saved["kind"] as? String == "raster" || (saved["kind"] as? String == "markdown" && saved["token"] != nil) {
                guard let actual=try? FileAttachments.validateReference(image),NSDictionary(dictionary:actual).isEqual(to:saved) else{throw refused()}
            } else if saved["kind"] as? String == "word" {
                guard let actual=try? WordAttachments.validateReference(image),NSDictionary(dictionary:actual).isEqual(to:saved) else{throw refused()}
            } else if saved["kind"] as? String == "pdf" {
                guard let actual=try? PDFAttachments.validateReference(image),NSDictionary(dictionary:actual).isEqual(to:saved) else{throw refused()}
            } else if saved["kind"] as? String == "video" {
                guard let actual=try? VideoAttachments.validateReference(image),NSDictionary(dictionary:actual).isEqual(to:saved) else{throw refused()}
            } else if saved["kind"] as? String == "markdown" {
                guard let actual = try? MarkdownAttachment.validate(image), NSDictionary(dictionary:actual).isEqual(to:saved) else { throw refused() }
            } else {guard image["kind"] == nil || image["kind"] as? String == "image",let data = image["data"] as? String,data == saved["data"] as? String else { throw refused() }}
        }
    }
    func load() throws -> Row {
        loaded = false
        let folder = try directoryFD();defer { close(folder) }
        let fd = openat(folder,"snapshot.json",O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if fd < 0 {
            guard errno == ENOENT else { throw failure() }
            loaded = true;return ["version":2,"drafts":[Row]()]
        }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd,&info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == getuid(),
              info.st_nlink == 1, info.st_size >= 0, info.st_size <= Self.maximumFileBytes, fchmod(fd,0o600) == 0 else { throw failure() }
        var data = Data(), buffer = [UInt8](repeating:0,count:65536)
        while true {
            let count = read(fd,&buffer,buffer.count)
            if count < 0 { if errno == EINTR { continue };throw failure() }
            if count == 0 { break }
            guard data.count + count <= Self.maximumFileBytes else { throw failure() }
            data.append(contentsOf:buffer.prefix(count))
        }
        let snapshot:Row
        do { snapshot = try Self.validate(JSONSerialization.jsonObject(with:data)) }
        catch { throw failure() }
        loaded = true;return snapshot
    }
    func save(_ value: Any) throws {
        guard loaded else { throw failure() }
        let snapshot = try Self.validate(value)
        let data = try JSONSerialization.data(withJSONObject:snapshot,options:[.sortedKeys])
        guard data.count <= Self.maximumFileBytes else { throw failure() }
        let folder = try directoryFD();defer { close(folder) }
        // Refuse a replaced target, including a symlink, before atomic replacement.
        var target = stat()
        let status = fstatat(folder,"snapshot.json",&target,AT_SYMLINK_NOFOLLOW)
        guard (status == 0 && (target.st_mode & S_IFMT) == S_IFREG && target.st_uid == getuid()) || (status != 0 && errno == ENOENT) else { throw failure() }
        let temporary = ".snapshot-" + UUID().uuidString
        let fd = openat(folder,temporary,O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,0o600)
        guard fd >= 0 else { throw failure() }
        defer { close(fd);unlinkat(folder,temporary,0) }
        guard fchmod(fd,0o600) == 0 else { throw failure() }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = write(fd,bytes.baseAddress!.advanced(by:offset),bytes.count-offset)
                if count < 0 { if errno == EINTR { continue };throw failure() }
                guard count > 0 else { throw failure() };offset += count
            }
        }
        guard fsync(fd) == 0, renameat(folder,temporary,folder,"snapshot.json") == 0 else { throw failure() }
        _ = fsync(folder)
    }
}
