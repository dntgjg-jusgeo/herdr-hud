import Foundation
import ImageIO
import UniformTypeIdentifiers
import Darwin
import CryptoKit

/// A gallery grants opaque, agent-scoped capabilities only for raster files it decoded.
/// No browser-supplied path or URL is accepted by the open operation.
final class PreviewGallery {
    static let maximumBytes = 24 * 1024 * 1024
    static let maximumItems = 24
    static let maximumEntries = 600
    struct FileStamp: Equatable {
        let device: dev_t, inode: ino_t, size: off_t, seconds: Int, nanos: Int
        init(_ value: stat) { device = value.st_dev; inode = value.st_ino; size = value.st_size; seconds = value.st_mtimespec.tv_sec; nanos = value.st_mtimespec.tv_nsec }
    }
    struct Entry { let agent: String, url: URL, stamp: FileStamp, root: URL, digest: Data }
    private var entries: [String:Entry] = [:]
    private var generations: [[String]] = []
    private let snapshots = FileManager.default.temporaryDirectory.appendingPathComponent("HerdrHUD-previews-" + UUID().uuidString,isDirectory:true)
    private var snapshotCount = 0
    private var snapshotBytes = 0
    private var copies: [String:URL] = [:]
    deinit { try? FileManager.default.removeItem(at:snapshots) }
    private let extensions: Set<String> = ["png","jpg","jpeg","webp","heic","tif","tiff","gif","bmp"]
    private let types: Set<String> = ["public.png","public.jpeg","org.webmproject.webp","public.heic","public.heif","public.tiff","com.compuserve.gif","com.microsoft.bmp"]

    static func canonical(_ url: URL) -> URL? {
        guard url.isFileURL, let path = realpath(url.path,nil) else { return nil }
        defer { free(path) }
        return URL(fileURLWithPath:String(cString:path),isDirectory:url.hasDirectoryPath)
    }
    static func localDirectory(_ url: URL) -> Bool {
        guard url.isFileURL, !url.path.hasPrefix("/net/"), !url.path.hasPrefix("/Network/") else { return false }
        let values = try? url.resourceValues(forKeys:[.isDirectoryKey,.volumeIsLocalKey])
        return values?.isDirectory == true && values?.volumeIsLocal == true
    }
    private func descriptor(_ url: URL, root: URL) throws -> (Int32, FileStamp) {
        guard url.isFileURL, url.deletingLastPathComponent().path == root.path,
              extensions.contains(url.pathExtension.lowercased()), Self.localDirectory(root),
              Self.canonical(url)?.path == url.path else { throw HUDError("This preview is no longer available. Refresh previews.") }
        // Walk every component through directory descriptors; never follow a swapped parent symlink.
        var parent = Darwin.open("/",O_RDONLY | O_DIRECTORY)
        guard parent >= 0 else { throw HUDError("Could not read preview folder.") }
        for component in root.pathComponents.dropFirst() {
            let next = openat(parent,component,O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            Darwin.close(parent); parent = next
            guard parent >= 0 else { throw HUDError("Preview folder changed. Refresh previews.") }
        }
        defer { Darwin.close(parent) }
        var filesystem = statfs()
        guard fstatfs(parent,&filesystem) == 0, filesystem.f_flags & UInt32(MNT_LOCAL) != 0 else { throw HUDError("Choose a local preview folder.") }
        let fd = openat(parent,url.lastPathComponent,O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw HUDError("This preview is no longer available. Refresh previews.") }
        var info = stat()
        guard fstat(fd,&info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size > 0, info.st_size <= Self.maximumBytes else {
            Darwin.close(fd); throw HUDError("Preview file is not a supported local image under 24 MB.")
        }
        return (fd, FileStamp(info))
    }
    func list(agent: String, directory: URL) throws -> Row {
        var generation: [String] = []
        defer { generations.append(generation); while generations.count > 3 { for token in generations.removeFirst() { entries.removeValue(forKey:token) } } }
        guard let base = Self.canonical(directory) else { throw HUDError("Choose an existing local folder for previews.") }
        guard Self.localDirectory(base) else { throw HUDError("Choose a folder on this Mac for previews.") }
        // Deliberately shallow: project root and outputs only. No recursive workspace scan.
        let roots = [base.appendingPathComponent("outputs",isDirectory:true),base].filter { Self.localDirectory($0) && Self.canonical($0)?.path == $0.path }
        var candidates: [(URL,FileStamp,URL)] = []
        var inspected = 0
        for root in roots {
            guard let iterator = FileManager.default.enumerator(at:root,includingPropertiesForKeys:nil,options:[.skipsHiddenFiles,.skipsSubdirectoryDescendants]) else { continue }
            while inspected < Self.maximumEntries, let url = iterator.nextObject() as? URL {
                inspected += 1
                guard let (fd,stamp) = try? descriptor(url,root:root) else { continue }
                Darwin.close(fd); candidates.append((url,stamp,root))
            }
        }
        candidates.sort { $0.1.seconds == $1.1.seconds ? $0.0.path < $1.0.path : $0.1.seconds > $1.1.seconds }
        var items: [Row] = []
        for (url,stamp,root) in candidates.prefix(48) {
            if items.count >= Self.maximumItems { break }
            guard let (fd,current) = try? descriptor(url,root:root) else { continue }
            guard current == stamp else { Darwin.close(fd); continue }
            let handle = FileHandle(fileDescriptor:fd,closeOnDealloc:true)
            let bytes = try? handle.read(upToCount:Self.maximumBytes + 1)
            try? handle.close()
            guard let data = bytes, data.count <= Self.maximumBytes,
                  let source = CGImageSourceCreateWithData(data as CFData,[kCGImageSourceShouldCache:false] as CFDictionary),
                  let type = CGImageSourceGetType(source), types.contains(type as String),
                  let props = CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any],
                  let width = props[kCGImagePropertyPixelWidth] as? Int, let height = props[kCGImagePropertyPixelHeight] as? Int,
                  width > 0, height > 0, width <= 32768, height <= 32768, width * height <= 100_000_000,
                  let thumbnail = CGImageSourceCreateThumbnailAtIndex(source,0,[kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceThumbnailMaxPixelSize:320,kCGImageSourceCreateThumbnailWithTransform:true] as CFDictionary) else { continue }
            let output = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(output,UTType.jpeg.identifier as CFString,1,nil) else { continue }
            CGImageDestinationAddImage(destination,thumbnail,[kCGImageDestinationLossyCompressionQuality:0.75] as CFDictionary)
            guard CGImageDestinationFinalize(destination), output.length <= 256 * 1024 else { continue }
            let token = UUID().uuidString
            generation.append(token)
            entries[token] = Entry(agent:agent,url:url,stamp:stamp,root:root,digest:Data(SHA256.hash(data:data)))
            items.append(["token":token,"name":url.lastPathComponent,"thumbnail":"data:image/jpeg;base64," + (output as Data).base64EncodedString(),"width":width,"height":height])
        }
        return ["id":agent,"folder":base.lastPathComponent,"items":items]
    }
    func snapshot(agent: String, token: String) throws -> URL {
        guard let entry = entries[token], entry.agent == agent else { throw HUDError("Refresh previews before opening this image.") }
        if let copy = copies[token] { return copy }
        let (fd,stamp) = try descriptor(entry.url,root:entry.root)
        let handle = FileHandle(fileDescriptor:fd,closeOnDealloc:true)
        defer { try? handle.close() }
        guard stamp == entry.stamp else { throw HUDError("This image changed. Refresh previews before opening it.") }
        // LaunchServices reopens by pathname. Hand it a private immutable copy so a
        // concurrent project writer cannot substitute another file after validation.
        guard snapshotCount < 96, snapshotBytes + Int(stamp.size) <= 192 * 1024 * 1024, let bytes = try handle.read(upToCount:Self.maximumBytes + 1), bytes.count == Int(stamp.size) else { throw HUDError("Preview copy limit reached. Reopen the HUD to clear its preview cache.") }
        var after = stat()
        guard fstat(fd,&after) == 0, FileStamp(after) == stamp, Data(SHA256.hash(data:bytes)) == entry.digest else { throw HUDError("Image changed while opening. Refresh previews.") }
        try FileManager.default.createDirectory(at:snapshots,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let folder = snapshots.appendingPathComponent(UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        let copy = folder.appendingPathComponent(entry.url.lastPathComponent)
        try bytes.write(to:copy,options:.withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions:0o400],ofItemAtPath:copy.path)
        snapshotCount += 1
        snapshotBytes += bytes.count
        copies[token] = copy
        return copy
    }
}
