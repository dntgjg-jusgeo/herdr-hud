import Foundation
import Darwin
import CoreFoundation
import CryptoKit
import AVFoundation
import AppKit
import ImageIO

/// Streamed private copies, addressed only by opaque tokens. Finalized assets
/// are retained: an acknowledged agent may still need their local paths later.
/// All methods belong to the caller's serial attachment queue.
final class VideoAttachments {
    static let maximumBytes = 100 * 1024 * 1024 // persisted legacy references
    static let maximumImportBytes = 50 * 1024 * 1024
    static let maximumChunkBytes = 1024 * 1024
    static let maximumCacheBytes = 512 * 1024 * 1024
    static let maximumAssets = 128
    let directory:URL
    private struct Pending { let fd:Int32;let name:String;let bytes:Int;var offset=0;var hash=SHA256();var touched=ProcessInfo.processInfo.systemUptime }
    private var pending:[String:Pending]=[:]
    typealias Inspector = (URL) throws -> Row
    private let inspect:Inspector
    init(directory:URL? = nil,inspect:@escaping Inspector = VideoAttachments.inspectVideo) {
        self.directory=directory ?? FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("Herdr HUD/Video Attachments",isDirectory:true)
        self.inspect=inspect
        try? cleanupIncomplete()
    }
    deinit { for token in Array(pending.keys){cancel(token:token)} }
    private static func failure(_ message:String = "Video attachment is unavailable or changed. Attach the MP4 again; saved drafts have been retained.") -> HUDError { HUDError(message) }
    private static func integer(_ value:Any?,maximum:Int)->Int? {
        guard let n=value as? NSNumber,CFGetTypeID(n) != CFBooleanGetTypeID(),n.doubleValue.isFinite,n.doubleValue.rounded(.down)==n.doubleValue,n.doubleValue>0,n.doubleValue<=Double(maximum) else{return nil};return n.intValue
    }
    private static func validToken(_ token:String)->Bool { token.range(of:"^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$",options:.regularExpression) != nil }
    static func validateReference(_ row:Row)throws->Row {
        guard row["kind"] as? String == "video",let token=row["token"] as? String,validToken(token),
              let name=row["name"] as? String,!name.isEmpty,name.utf8.count<=480,name.utf16.count<=120,name.lowercased().hasSuffix(".mp4"),
              !name.contains("/"),!name.contains("\\"),name.rangeOfCharacter(from:.controlCharacters)==nil,
              let bytes=integer(row["bytes"],maximum:maximumBytes),let width=integer(row["width"],maximum:16384),let height=integer(row["height"],maximum:16384),width*height<=40_000_000,
              let n=row["duration"] as? NSNumber,CFGetTypeID(n) != CFBooleanGetTypeID(),n.doubleValue.isFinite,n.doubleValue>0,n.doubleValue<=86400,
              let poster=row["poster"] as? String,poster.utf8.count<=350000,poster.hasPrefix("data:image/jpeg;base64,"),
              let jpeg=Data(base64Encoded:String(poster.dropFirst("data:image/jpeg;base64,".count))),!jpeg.isEmpty,
              let image=CGImageSourceCreateWithData(jpeg as CFData,[kCGImageSourceShouldCache:false] as CFDictionary),CGImageSourceGetType(image) as String? == "public.jpeg",
              let properties=CGImageSourceCopyPropertiesAtIndex(image,0,nil) as? [CFString:Any],
              let w=integer(properties[kCGImagePropertyPixelWidth],maximum:640),let h=integer(properties[kCGImagePropertyPixelHeight],maximum:640),w*h<=640*640 else {throw failure("Invalid MP4 attachment reference.")}
        return ["kind":"video","token":token,"name":name,"bytes":bytes,"poster":poster,"duration":n.doubleValue,"width":width,"height":height]
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
            total+=Int(info.st_size);count+=1;if name.hasSuffix(".mp4"){assets+=1}
            guard total<=Self.maximumCacheBytes,count<=Self.maximumAssets*3 else{throw Self.failure("Video cache is full. Existing clips have been retained.")}
        }
        return(total,assets)
    }
    func begin(name:String,bytes:Int)throws->String {
        try cleanupIncomplete()
        guard bytes>0,bytes<=Self.maximumImportBytes,pending.count<3,!name.isEmpty,name.utf8.count<=480,name.lowercased().hasSuffix(".mp4"),
              !name.contains("/"),!name.contains("\\"),name.rangeOfCharacter(from:.controlCharacters)==nil else{throw Self.failure("Attach an MP4 up to 50 MiB, with at most three imports at once.")}
        let dir=try folder();defer{close(dir)}
        let reserved=pending.values.reduce(0){$0+$1.bytes-$1.offset+350000}
        let current=try usage(dir)
        guard current.assets<Self.maximumAssets,current.bytes+reserved+bytes+350000<=Self.maximumCacheBytes else{throw Self.failure("Video cache totals 512 MB or 128 clips. Existing clips have been retained.")}
        var stem=""
        for scalar in name.dropLast(4).unicodeScalars {let next=stem+String(scalar);if next.utf16.count>116{break};stem=next}
        let display=stem+".mp4"
        let token=UUID().uuidString.lowercased(),fd=openat(dir,token+".part.mp4",O_RDWR|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0o600)
        guard fd>=0 else{throw Self.failure()};pending[token]=Pending(fd:fd,name:display,bytes:bytes);return token
    }
    func append(token:String,offset:Int,dataBase64:String)throws {
        guard var item=pending[token],offset==item.offset,dataBase64.utf8.count<=((Self.maximumChunkBytes+2)/3)*4,
              let bytes=Data(base64Encoded:dataBase64),!bytes.isEmpty,bytes.count<=Self.maximumChunkBytes,item.offset+bytes.count<=item.bytes else{throw Self.failure("Video import chunk changed or exceeds its limit.")}
        try bytes.withUnsafeBytes { raw in
            var sent=0
            while sent<raw.count {let n=write(item.fd,raw.baseAddress!.advanced(by:sent),raw.count-sent);if n<0 && errno==EINTR{continue};guard n>0 else{throw Self.failure()};sent+=n}
        }
        item.offset+=bytes.count;item.hash.update(data:bytes);item.touched=ProcessInfo.processInfo.systemUptime;pending[token]=item
    }
    func cancel(token:String) {
        guard let item=pending.removeValue(forKey:token) else{return};close(item.fd)
        if let dir=try? folder(){_ = unlinkat(dir,token+".part.mp4",0);close(dir)}
    }
    private func cleanupIncomplete()throws {
        let expired=pending.filter{ProcessInfo.processInfo.systemUptime-$0.value.touched>300}.map(\.key)
        for token in expired{cancel(token:token)}
        let dir=try folder();defer{close(dir)}
        let duplicate=dup(dir);guard duplicate>=0,let stream=fdopendir(duplicate) else{if duplicate>=0{close(duplicate)};throw Self.failure()};defer{closedir(stream)}
        while let entry=readdir(stream) {
            let name=withUnsafePointer(to:&entry.pointee.d_name){$0.withMemoryRebound(to:CChar.self,capacity:Int(MAXNAMLEN)+1){String(cString:$0)}}
            let suffix=name.hasSuffix(".part.mp4") ? ".part.mp4" : name.hasSuffix(".metadata.part") ? ".metadata.part" : ""
            guard !suffix.isEmpty else{continue}
            let token=String(name.dropLast(suffix.count));guard Self.validToken(token),pending[token]==nil else{continue}
            let (fd,info)=try checkedFile(dir,name,maximum:Self.maximumBytes);close(fd)
            guard Date().timeIntervalSince1970-Double(info.st_mtimespec.tv_sec)>3600 else{continue}
            guard unlinkat(dir,name,0)==0 || errno==ENOENT else{throw Self.failure()}
        }
    }
    func importFile(_ url:URL)throws->Row {
        guard url.isFileURL,url.host == nil || url.host == "" || url.host == "localhost",url.pathExtension.lowercased()=="mp4" else{throw Self.failure("Choose a local MP4 file.")}
        let fd=open(url.path,O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC);guard fd>=0 else{throw Self.failure("Cannot open this local MP4.")};defer{close(fd)}
        var before=stat();guard fstat(fd,&before)==0,(before.st_mode&S_IFMT)==S_IFREG,before.st_size>0,before.st_size<=Self.maximumImportBytes else{throw Self.failure("Use a regular MP4 file up to 50 MiB.")}
        let token=try begin(name:url.lastPathComponent,bytes:Int(before.st_size))
        do {
            var buffer=[UInt8](repeating:0,count:Self.maximumChunkBytes),offset=0
            while true {
                let n=read(fd,&buffer,buffer.count);if n<0 && errno==EINTR{continue};guard n>=0 else{throw Self.failure()};if n==0{break}
                try append(token:token,offset:offset,dataBase64:Data(buffer.prefix(n)).base64EncodedString());offset+=n
            }
            var after=stat(),named=stat()
            guard fstat(fd,&after)==0,lstat(url.path,&named)==0,(named.st_mode&S_IFMT)==S_IFREG,
                  named.st_dev==before.st_dev,named.st_ino==before.st_ino,after.st_size==before.st_size,
                  after.st_mtimespec.tv_sec==before.st_mtimespec.tv_sec,after.st_mtimespec.tv_nsec==before.st_mtimespec.tv_nsec,
                  after.st_ctimespec.tv_sec==before.st_ctimespec.tv_sec,after.st_ctimespec.tv_nsec==before.st_ctimespec.tv_nsec else{throw Self.failure("The MP4 changed during import. Attach it again.")}
            return try finish(token:token)
        }catch{cancel(token:token);throw error}
    }
    func finish(token:String)throws->Row {
        guard let item=pending[token],item.offset==item.bytes,fsync(item.fd)==0 else{throw Self.failure("Video import is incomplete. Try attaching the MP4 again.")}
        let dir=try folder();defer{close(dir)}
        let (fd,info)=try checkedFile(dir,token+".part.mp4",maximum:Self.maximumBytes);defer{close(fd)}
        var opened=stat();guard fstat(item.fd,&opened)==0,opened.st_dev==info.st_dev,opened.st_ino==info.st_ino,info.st_size==item.bytes else{throw Self.failure()}
        var header=[UInt8](repeating:0,count:16);guard pread(fd,&header,header.count,0)==16,String(bytes:header[4..<8],encoding:.ascii)=="ftyp" else{throw Self.failure("Use a valid MP4 containing a video track.")}
        let metadata=try inspect(directory.appendingPathComponent(token+".part.mp4"))
        var row=metadata;row["kind"]="video";row["token"]=token;row["name"]=item.name;row["bytes"]=item.bytes
        row=try Self.validateReference(row)
        var record=row;record["sha256"]=item.hash.finalize().map{String(format:"%02x",$0)}.joined()
        let data=try JSONSerialization.data(withJSONObject:record,options:[.sortedKeys]),temporary=token+".metadata.part"
        let out=openat(dir,temporary,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0o600);guard out>=0 else{throw Self.failure()}
        do {
            try data.withUnsafeBytes { raw in var sent=0;while sent<raw.count{let n=write(out,raw.baseAddress!.advanced(by:sent),raw.count-sent);if n<0 && errno==EINTR{continue};guard n>0 else{throw Self.failure()};sent+=n} }
            guard fsync(out)==0 else{throw Self.failure()};close(out)
        } catch {close(out);_ = unlinkat(dir,temporary,0);throw error}
        guard renameat(dir,token+".part.mp4",dir,token+".mp4")==0,renameat(dir,temporary,dir,token+".json")==0,fsync(dir)==0 else{throw Self.failure()}
        pending.removeValue(forKey:token);close(item.fd);return row
    }
    func reference(_ row:Row,verifyContent:Bool = true)throws->URL {
        let safe=try Self.validateReference(row),token=safe["token"] as! String
        let dir=try folder();defer{close(dir)}
        let (meta,_)=try checkedFile(dir,token+".json",maximum:400000);defer{close(meta)}
        var data=Data(),buffer=[UInt8](repeating:0,count:65536)
        while true{let n=read(meta,&buffer,buffer.count);if n<0 && errno==EINTR{continue};guard n>=0,data.count+n<=400000 else{throw Self.failure()};if n==0{break};data.append(contentsOf:buffer.prefix(n))}
        guard let record=try JSONSerialization.jsonObject(with:data) as? Row,
              NSDictionary(dictionary:try Self.validateReference(record)).isEqual(to:safe),let expected=record["sha256"] as? String,expected.range(of:"^[a-f0-9]{64}$",options:.regularExpression) != nil else{throw Self.failure()}
        let (fd,info)=try checkedFile(dir,token+".mp4",maximum:Self.maximumBytes);defer{close(fd)}
        guard Int(info.st_size)==safe["bytes"] as? Int else{throw Self.failure()}
        if verifyContent {
            var hash=SHA256(),count=0
            while true{let n=read(fd,&buffer,buffer.count);if n<0 && errno==EINTR{continue};guard n>=0,count+n<=Self.maximumBytes else{throw Self.failure()};if n==0{break};count+=n;hash.update(data:Data(buffer.prefix(n)))}
            var after=stat()
            guard count==info.st_size,fstat(fd,&after)==0,after.st_size==info.st_size,after.st_mtimespec.tv_sec==info.st_mtimespec.tv_sec,
                  after.st_mtimespec.tv_nsec==info.st_mtimespec.tv_nsec,after.st_ctimespec.tv_sec==info.st_ctimespec.tv_sec,after.st_ctimespec.tv_nsec==info.st_ctimespec.tv_nsec,
                  hash.finalize().map({String(format:"%02x",$0)}).joined()==expected else{throw Self.failure()}
        }
        return directory.appendingPathComponent(token+".mp4")
    }
    static func inspectVideo(_ url:URL)throws->Row {
        // ForbidAll prevents self-contained local clips from loading external
        // movie references, including network URLs and adjacent local files.
        let asset=AVURLAsset(url:url,options:[AVURLAssetReferenceRestrictionsKey:NSNumber(value:0xffff)]),ready=DispatchSemaphore(value:0)
        asset.loadValuesAsynchronously(forKeys:["duration","tracks","playable"]){ready.signal()}
        guard ready.wait(timeout:.now()+8) == .success else{asset.cancelLoading();throw failure("MP4 preview timed out. Try a shorter clip.")}
        var error:NSError?
        guard ["duration","tracks","playable"].allSatisfy({asset.statusOfValue(forKey:$0,error:&error) == .loaded}),asset.isPlayable,
              let track=asset.tracks(withMediaType:.video).first else{throw failure("Use a playable MP4 containing a video track.")}
        let size=track.naturalSize.applying(track.preferredTransform)
        guard size.width.isFinite,size.height.isFinite,abs(size.width)>=1,abs(size.height)>=1,abs(size.width)<=16384,abs(size.height)<=16384 else{throw failure("MP4 dimensions exceed the preview limit.")}
        let width=Int(abs(size.width)),height=Int(abs(size.height)),duration=CMTimeGetSeconds(asset.duration)
        guard width>0,height>0,width<=16384,height<=16384,width*height<=40_000_000,duration.isFinite,duration>0,duration<=86400 else{throw failure("MP4 dimensions or duration exceed the preview limit.")}
        let generator=AVAssetImageGenerator(asset:asset);generator.appliesPreferredTrackTransform=true;generator.maximumSize=CGSize(width:640,height:640)
        final class Poster {var image:CGImage?}
        let poster=Poster(),done=DispatchSemaphore(value:0)
        generator.generateCGImagesAsynchronously(forTimes:[NSValue(time:.zero)]){_,image,_,result,_ in
            if result == .succeeded{poster.image=image};done.signal()
        }
        guard done.wait(timeout:.now()+8) == .success,let image=poster.image else{generator.cancelAllCGImageGeneration();throw failure("MP4 poster preview timed out or could not be decoded.")}
        let bitmap=NSBitmapImageRep(cgImage:image)
        guard let jpeg=bitmap.representation(using:.jpeg,properties:[.compressionFactor:0.65]),jpeg.count<=250000 else{throw failure("Could not create a bounded MP4 preview.")}
        return ["poster":"data:image/jpeg;base64,"+jpeg.base64EncodedString(),"duration":duration,"width":width,"height":height]
    }
}
