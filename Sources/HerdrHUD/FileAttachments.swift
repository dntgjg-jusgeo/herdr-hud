import Foundation
import Darwin
import CoreFoundation
import CryptoKit
import ImageIO
import AppKit

/// Private immutable copies. Call on the serial attachment queue; finalized
/// assets remain available to acknowledged and uncertain agent submissions.
final class FileAttachments {
    static let maximumBytes = 100 * 1024 * 1024
    static let maximumMarkdownBytes = 10 * 1024 * 1024
    static let maximumCacheBytes = 512 * 1024 * 1024
    static let maximumAssets = 128
    private struct Pending {let fd:Int32;let name:String;let bytes:Int;var offset=0;var touched=ProcessInfo.processInfo.systemUptime}
    private var pending:[String:Pending]=[:]
    deinit {for token in Array(pending.keys){cancel(token:token)}}
    let directory:URL
    init(directory:URL? = nil) {
        self.directory=directory ?? FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("Herdr HUD/File Attachments",isDirectory:true)
        try? cleanupIncomplete()
    }
    private static func failure(_ message:String = "File attachment is unavailable or changed. Attach the file again; your draft is retained.")->HUDError { HUDError(message) }
    private static func integer(_ value:Any?,maximum:Int)->Int? {
        guard let n=value as? NSNumber,CFGetTypeID(n) != CFBooleanGetTypeID(),n.doubleValue.isFinite,n.doubleValue.rounded(.down)==n.doubleValue,n.doubleValue>0,n.doubleValue<=Double(maximum) else{return nil};return n.intValue
    }
    private static func validToken(_ token:String)->Bool {token.range(of:"^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$",options:.regularExpression) != nil}
    static func kind(name:String)->String? {
        let ext=(name as NSString).pathExtension.lowercased()
        return ["md","markdown"].contains(ext) ? "markdown" : ["png","jpg","jpeg","webp","gif"].contains(ext) ? "raster" : nil
    }
    static func validateReference(_ row:Row)throws->Row {
        guard let token=row["token"] as? String,validToken(token),let name=row["name"] as? String,
              !name.isEmpty,name.utf16.count<=120,!name.contains("/"),!name.contains("\\"),
              name.rangeOfCharacter(from:.controlCharacters)==nil,let kind=kind(name:name),row["kind"] as? String == kind,
              let bytes=integer(row["bytes"],maximum:kind == "markdown" ? maximumMarkdownBytes:maximumBytes) else{throw failure("Invalid file attachment reference.")}
        var safe:Row=["kind":kind,"token":token,"name":name,"bytes":bytes]
        if let poster=row["poster"] {
            guard kind == "raster",let value=poster as? String,value.utf8.count<=50000,value.hasPrefix("data:image/jpeg;base64,"),let data=Data(base64Encoded:String(value.dropFirst(23))),let source=CGImageSourceCreateWithData(data as CFData,nil),let props=CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any],let w=props[kCGImagePropertyPixelWidth] as? Int,let h=props[kCGImagePropertyPixelHeight] as? Int,w>0,h>0,w<=200,h<=200 else{throw failure("Invalid image preview.")}
            _ = try ImageAttachment.parse([["data":data.base64EncodedString()]])
            safe["poster"]=value
        }
        return safe
    }
    private func folder()throws->Int32 {
        guard directory.path.hasPrefix("/") else {throw Self.failure()}
        var fd=open("/",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);guard fd>=0 else {throw Self.failure()}
        for component in directory.pathComponents where component != "/" {
            guard component != ".",component != ".." else {close(fd);throw Self.failure()}
            var next=openat(fd,component,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC)
            if next<0 && errno==ENOENT {
                guard mkdirat(fd,component,0o700)==0 || errno==EEXIST else{close(fd);throw Self.failure()}
                next=openat(fd,component,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC)
            }
            close(fd);guard next>=0 else{throw Self.failure()};fd=next
        }
        var info=stat();guard fstat(fd,&info)==0,info.st_uid==geteuid(),fchmod(fd,0o700)==0 else{close(fd);throw Self.failure()};return fd
    }
    private func checkedFile(_ folder:Int32,_ name:String,maximum:Int)throws->(Int32,stat) {
        let fd=openat(folder,name,O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC);guard fd>=0 else{throw Self.failure()}
        var info=stat();guard fstat(fd,&info)==0,(info.st_mode&S_IFMT)==S_IFREG,info.st_uid==geteuid(),info.st_nlink==1,info.st_size>=0,info.st_size<=maximum,(info.st_mode&0o077)==0 else{close(fd);throw Self.failure()};return(fd,info)
    }
    private func usage(_ folder:Int32)throws->(bytes:Int,assets:Int) {
        let duplicate=dup(folder);guard duplicate>=0,let stream=fdopendir(duplicate) else{if duplicate>=0{close(duplicate)};throw Self.failure()};defer{closedir(stream)}
        var total=0,count=0,assets=0
        while let entry=readdir(stream) {
            let name=withUnsafePointer(to:&entry.pointee.d_name){$0.withMemoryRebound(to:CChar.self,capacity:Int(MAXNAMLEN)+1){String(cString:$0)}}
            if name=="." || name==".."{continue}
            let (fd,info)=try checkedFile(folder,name,maximum:Self.maximumCacheBytes);close(fd)
            total+=Int(info.st_size);count+=1;if !name.hasSuffix(".json"){assets+=1}
            guard total<=Self.maximumCacheBytes,count<=Self.maximumAssets*3 else{throw Self.failure("File cache is full. Existing files have been retained.")}
        }
        return(total,assets)
    }
    private static func readBounded(_ fd:Int32,maximum:Int)throws->Data {
        var data=Data(),buffer=[UInt8](repeating:0,count:65536)
        while true {let n=read(fd,&buffer,buffer.count);if n<0 && errno==EINTR{continue};guard n>=0,data.count+n<=maximum else{throw failure()};if n==0{break};data.append(contentsOf:buffer.prefix(n))}
        return data
    }
    private static func unchanged(_ a:stat,_ b:stat)->Bool {
        a.st_dev==b.st_dev && a.st_ino==b.st_ino && a.st_size==b.st_size && a.st_mtimespec.tv_sec==b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec==b.st_mtimespec.tv_nsec && a.st_ctimespec.tv_sec==b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec==b.st_ctimespec.tv_nsec
    }
    func importFile(_ url:URL,name:String? = nil)throws->Row {
        guard url.isFileURL,url.host == nil || url.host == "" || url.host == "localhost",Self.kind(name:url.lastPathComponent) != nil else{throw Self.failure("Choose a local file up to 100 MiB (Markdown 10 MiB).")}
        let fd=open(url.path,O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC);guard fd>=0 else{throw Self.failure("Cannot open this local file. Attach a readable regular file.")};defer{close(fd)}
        var before=stat();guard fstat(fd,&before)==0,before.st_mode&S_IFMT == S_IFREG,before.st_size>0,before.st_size<=(Self.kind(name:url.lastPathComponent) == "markdown" ? Self.maximumMarkdownBytes:Self.maximumBytes) else{throw Self.failure("Attach a regular file up to 100 MiB (Markdown 10 MiB).")}
        let data=try Self.readBounded(fd,maximum:Self.kind(name:url.lastPathComponent) == "markdown" ? Self.maximumMarkdownBytes:Self.maximumBytes)
        var after=stat(),named=stat()
        guard fstat(fd,&after)==0,lstat(url.path,&named)==0,named.st_mode&S_IFMT == S_IFREG,Self.unchanged(before,after),Self.unchanged(before,named),data.count==before.st_size else{throw Self.failure("The file changed during import. Attach it again.")}
        return try store(name:name ?? url.lastPathComponent,data:data)
    }
    func importData(name:String,dataBase64:String)throws->Row {
        guard dataBase64.utf8.count<=((Self.maximumBytes+2)/3)*4,let data=Data(base64Encoded:dataBase64),!data.isEmpty,data.count<=Self.maximumBytes else{throw Self.failure("Attach a file up to 100 MiB (Markdown 10 MiB).")}
        return try store(name:name,data:data)
    }
    private func writeFile(_ dir:Int32,name:String,data:Data)throws {
        let fd=openat(dir,name,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0o600);guard fd>=0 else{throw Self.failure()};defer{close(fd)}
        try data.withUnsafeBytes { raw in var offset=0;while offset<raw.count {let n=write(fd,raw.baseAddress!.advanced(by:offset),raw.count-offset);if n<0 && errno==EINTR{continue};guard n>0 else{throw Self.failure()};offset+=n} }
        guard fsync(fd)==0 else{throw Self.failure()}
    }
    private func store(name:String,data:Data)throws->Row {
        guard let kind=Self.kind(name:name) else {throw Self.failure("Unsupported attachment type.")}
        if kind == "markdown" {
            guard data.count<=Self.maximumMarkdownBytes,let text=String(data:data,encoding:.utf8),!text.contains("\0") else {throw Self.failure("Use valid UTF-8 Markdown up to 10 MiB, without NUL characters.")}
        } else {_ = try Self.normalizedImage(data:data)}
        let token=UUID().uuidString.lowercased()
        var value:Row=["kind":kind,"token":token,"name":name,"bytes":data.count]
        if kind == "raster" {
            guard let source=CGImageSourceCreateWithData(data as CFData,[kCGImageSourceShouldCache:false] as CFDictionary),let image=CGImageSourceCreateThumbnailAtIndex(source,0,[kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceCreateThumbnailWithTransform:true,kCGImageSourceThumbnailMaxPixelSize:200] as CFDictionary),let jpeg=NSBitmapImageRep(cgImage:image).representation(using:.jpeg,properties:[.compressionFactor:0.65]) else{throw Self.failure("Could not create image preview.")}
            value["poster"]="data:image/jpeg;base64,"+jpeg.base64EncodedString()
        }
        let row=try Self.validateReference(value)
        let dir=try folder();defer{close(dir)}
        let current=try usage(dir)
        var record=row;record["sha256"]=SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()
        let metadata=try JSONSerialization.data(withJSONObject:record,options:[.sortedKeys])
        guard current.assets<Self.maximumAssets,current.bytes+data.count+metadata.count<=Self.maximumCacheBytes else{throw Self.failure("File cache totals 512 MiB or 128 files. Existing files have been retained.")}
        let asset=token+"."+(name as NSString).pathExtension.lowercased(),part=token+".part",metaPart=token+".metadata.part"
        defer{_ = unlinkat(dir,part,0);_ = unlinkat(dir,metaPart,0)}
        try writeFile(dir,name:part,data:data);try writeFile(dir,name:metaPart,data:metadata)
        guard renameat(dir,part,dir,asset)==0,renameat(dir,metaPart,dir,token+".json")==0,fsync(dir)==0 else{throw Self.failure()}
        return row
    }
    func reference(_ row:Row,verifyContent:Bool = true)throws->URL {
        let safe=try Self.validateReference(row),token=safe["token"] as! String,asset=token+"."+((safe["name"] as! String) as NSString).pathExtension.lowercased()
        let dir=try folder();defer{close(dir)}
        let (meta,_)=try checkedFile(dir,token+".json",maximum:65536);defer{close(meta)}
        let metadata=try Self.readBounded(meta,maximum:65536)
        guard let record=try JSONSerialization.jsonObject(with:metadata) as? Row,NSDictionary(dictionary:try Self.validateReference(record)).isEqual(to:safe),let expected=record["sha256"] as? String,expected.range(of:"^[a-f0-9]{64}$",options:.regularExpression) != nil else{throw Self.failure()}
        let (fd,info)=try checkedFile(dir,asset,maximum:Self.maximumBytes);defer{close(fd)}
        guard Int(info.st_size)==safe["bytes"] as? Int else{throw Self.failure()}
        if verifyContent {
            let data=try Self.readBounded(fd,maximum:Self.maximumBytes);var after=stat(),named=stat()
            guard data.count==info.st_size,fstat(fd,&after)==0,fstatat(dir,asset,&named,AT_SYMLINK_NOFOLLOW)==0,Self.unchanged(info,after),Self.unchanged(info,named),SHA256.hash(data:data).map({String(format:"%02x",$0)}).joined()==expected else{throw Self.failure()}
        }
        return directory.appendingPathComponent(asset)
    }
    // All browser imports stream 1 MiB bridge chunks; no large data URL or image decoding in WebKit.
    private func cleanupIncomplete()throws {
        for token in pending.filter({ProcessInfo.processInfo.systemUptime-$0.value.touched>300}).map(\.key){cancel(token:token)}
        let dir=try folder();defer{close(dir)}
        let duplicate=dup(dir);guard duplicate>=0,let stream=fdopendir(duplicate) else{if duplicate>=0{close(duplicate)};throw Self.failure()};defer{closedir(stream)}
        while let entry=readdir(stream) {
            let name=withUnsafePointer(to:&entry.pointee.d_name){$0.withMemoryRebound(to:CChar.self,capacity:Int(MAXNAMLEN)+1){String(cString:$0)}}
            let pieces=name.components(separatedBy:".upload.")
            guard pieces.count==2,Self.validToken(pieces[0]),pending[pieces[0]]==nil,["md","markdown","png","jpg","jpeg","webp","gif","pdf","docx"].contains(pieces[1]) else{continue}
            let (fd,info)=try checkedFile(dir,name,maximum:Self.maximumBytes);close(fd)
            if Date().timeIntervalSince1970-Double(info.st_mtimespec.tv_sec)>3600 {guard unlinkat(dir,name,0)==0 || errno==ENOENT else{throw Self.failure()}}
        }
    }
    func begin(name:String,bytes:Int)throws->String {
        try cleanupIncomplete()
        let ext=(name as NSString).pathExtension.lowercased(),maximum=["md","markdown"].contains(ext) ? Self.maximumMarkdownBytes:Self.maximumBytes
        guard Self.kind(name:name) != nil || ["pdf","docx"].contains(ext),!name.contains("/"),!name.contains("\\"),name.utf16.count<=120,name.rangeOfCharacter(from:.controlCharacters)==nil,bytes>0,bytes<=maximum,pending.count<3 else{throw Self.failure("Attach a supported file up to 100 MiB (Markdown 10 MiB).")}
        let dir=try folder();defer{close(dir)};let current=try usage(dir)
        guard current.bytes+pending.values.reduce(0,{$0+$1.bytes-$1.offset})+bytes+4096<=Self.maximumCacheBytes else{throw Self.failure("File cache is full; existing originals are retained.")}
        let token=UUID().uuidString.lowercased(),fd=openat(dir,token+".upload."+ext,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0o600)
        guard fd>=0 else{throw Self.failure()};pending[token]=Pending(fd:fd,name:name,bytes:bytes);return token
    }
    func append(token:String,offset:Int,dataBase64:String)throws {
        guard var item=pending[token],offset==item.offset,dataBase64.utf8.count<=1398104,let data=Data(base64Encoded:dataBase64),!data.isEmpty,data.count<=1024*1024,item.offset+data.count<=item.bytes else{throw Self.failure("File upload chunk changed or exceeds its limit.")}
        try data.withUnsafeBytes{raw in var sent=0;while sent<raw.count{let n=write(item.fd,raw.baseAddress!.advanced(by:sent),raw.count-sent);if n<0 && errno==EINTR{continue};guard n>0 else{throw Self.failure()};sent+=n}}
        item.offset+=data.count;item.touched=ProcessInfo.processInfo.systemUptime;pending[token]=item
    }
    func cancel(token:String){
        guard let item=pending.removeValue(forKey:token) else{return};close(item.fd)
        if let dir=try? folder(){_ = unlinkat(dir,token+".upload."+(item.name as NSString).pathExtension.lowercased(),0);close(dir)}
    }
    func finish(token:String,importer:(URL,String)throws->Row)throws->Row {
        guard let item=pending[token],item.offset==item.bytes,fsync(item.fd)==0 else{throw Self.failure("File upload is incomplete.")}
        defer{cancel(token:token)}
        let url=directory.appendingPathComponent(token+".upload."+(item.name as NSString).pathExtension.lowercased())
        return try importer(url,item.name)
    }
    static func normalizedImage(data:Data)throws->Row {
        guard data.count<=maximumBytes,let source=CGImageSourceCreateWithData(data as CFData,[kCGImageSourceShouldCache:false] as CFDictionary),
              let type=CGImageSourceGetType(source) as String?,["public.png","public.jpeg","org.webmproject.webp","com.compuserve.gif"].contains(type),
              let properties=CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any],
              let width=properties[kCGImagePropertyPixelWidth] as? Int,let height=properties[kCGImagePropertyPixelHeight] as? Int,
              width>0,height>0,width<=65535,height<=65535,width*height<=250_000_000 else{throw failure("Use a supported raster image up to 100 MiB and 250 million pixels.")}
        for dimension in [2000,1536,1024] {
            guard let image=CGImageSourceCreateThumbnailAtIndex(source,0,[kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceCreateThumbnailWithTransform:true,kCGImageSourceThumbnailMaxPixelSize:dimension,kCGImageSourceShouldCacheImmediately:true] as CFDictionary) else{throw failure("This image could not be decoded safely. Export a PNG or JPEG copy.")}
            let bitmap=NSBitmapImageRep(cgImage:image)
            if let jpeg=bitmap.representation(using:.jpeg,properties:[.compressionFactor:0.82]),jpeg.count<=ImageAttachment.maximumBytes {
                let row:Row=["data":jpeg.base64EncodedString()];_ = try ImageAttachment.parse([row]);return row
            }
        }
        throw failure("This image could not be normalized within provider image limits. Export a smaller PNG or JPEG copy.")
    }
    func prepare(_ row:Row)throws->(url:URL,image:Row?,summary:String) {
        let safe=try Self.validateReference(row),url=try reference(safe)
        let dir=try folder();defer{close(dir)}
        let (fd,info)=try checkedFile(dir,url.lastPathComponent,maximum:Self.maximumBytes);defer{close(fd)}
        let data=try Self.readBounded(fd,maximum:Self.maximumBytes)
        var after=stat();guard data.count==safe["bytes"] as? Int,fstat(fd,&after)==0,Self.unchanged(info,after) else{throw Self.failure()}
        if safe["kind"] as? String == "raster" {
            return(url,try Self.normalizedImage(data:data),"The image attachment is a normalized first-frame overview (at most 2000 pixels on its longest edge); animation, transparency and fine detail may differ. Read the full original local image with tools when needed.")
        }
        guard let text=String(data:data,encoding:.utf8),!text.contains("\0") else{throw Self.failure()}
        let excerpt=String(text.prefix(2000))
        return(url,nil,"Full immutable UTF-8 Markdown file: \(encode(url.path)). Read this entire file with local tools, in chunks as needed, before answering. The following quoted preview is only \(excerpt.utf8.count) of \(data.count) UTF-8 bytes; it is not the complete document unless those counts match. No file content was dropped from the original.\nQuoted preview: \(encode(excerpt))")
    }

}
