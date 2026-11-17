import Foundation
import Darwin
import CoreFoundation
import CryptoKit

/// Private immutable copies. Call on the serial attachment queue; finalized
/// assets remain available to acknowledged and uncertain agent submissions.
final class WordAttachments {
    static let maximumBytes = 100 * 1024 * 1024
    static let maximumCacheBytes = 512 * 1024 * 1024
    static let maximumAssets = 128
    let directory:URL
    init(directory:URL? = nil) {
        self.directory=directory ?? FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("Herdr HUD/Word Attachments",isDirectory:true)
    }
    private static func failure(_ message:String = "Word attachment is unavailable or changed. Attach the Word again; your draft is retained.")->HUDError { HUDError(message) }
    private static func integer(_ value:Any?,maximum:Int)->Int? {
        guard let n=value as? NSNumber,CFGetTypeID(n) != CFBooleanGetTypeID(),n.doubleValue.isFinite,n.doubleValue.rounded(.down)==n.doubleValue,n.doubleValue>0,n.doubleValue<=Double(maximum) else{return nil};return n.intValue
    }
    private static func validToken(_ token:String)->Bool {token.range(of:"^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$",options:.regularExpression) != nil}
    static func validateReference(_ row:Row)throws->Row {
        guard row["kind"] as? String == "word",let token=row["token"] as? String,validToken(token),
              let name=row["name"] as? String,!name.isEmpty,name.utf16.count<=120,name.lowercased().hasSuffix(".docx"),!name.dropLast(5).isEmpty,
              !name.contains("/"),!name.contains("\\"),name.rangeOfCharacter(from:.controlCharacters)==nil,
              let bytes=integer(row["bytes"],maximum:maximumBytes) else{throw failure("Invalid Word attachment reference.")}
        return ["kind":"word","token":token,"name":name,"bytes":bytes]
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
            total+=Int(info.st_size);count+=1;if name.hasSuffix(".docx"){assets+=1}
            guard total<=Self.maximumCacheBytes,count<=Self.maximumAssets*3 else{throw Self.failure("Word cache is full. Existing Word documents have been retained.")}
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
        guard url.isFileURL,url.host == nil || url.host == "" || url.host == "localhost",url.pathExtension.lowercased()=="docx" else{throw Self.failure("Choose a local Word file up to 100 MiB.")}
        let fd=open(url.path,O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC);guard fd>=0 else{throw Self.failure("Cannot open this local Word. Attach a readable regular file.")};defer{close(fd)}
        var before=stat();guard fstat(fd,&before)==0,before.st_mode&S_IFMT == S_IFREG,before.st_size>0,before.st_size<=Self.maximumBytes else{throw Self.failure("Attach a regular Word file up to 100 MiB.")}
        let data=try Self.readBounded(fd,maximum:Self.maximumBytes)
        var after=stat(),named=stat()
        guard fstat(fd,&after)==0,lstat(url.path,&named)==0,named.st_mode&S_IFMT == S_IFREG,Self.unchanged(before,after),Self.unchanged(before,named),data.count==before.st_size else{throw Self.failure("The Word changed during import. Attach it again.")}
        return try store(name:name ?? url.lastPathComponent,data:data)
    }
    func importData(name:String,dataBase64:String)throws->Row {
        guard dataBase64.utf8.count<=((Self.maximumBytes+2)/3)*4,let data=Data(base64Encoded:dataBase64),!data.isEmpty,data.count<=Self.maximumBytes else{throw Self.failure("Attach a Word up to 100 MiB.")}
        return try store(name:name,data:data)
    }
    private func writeFile(_ dir:Int32,name:String,data:Data)throws {
        let fd=openat(dir,name,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0o600);guard fd>=0 else{throw Self.failure()};defer{close(fd)}
        try data.withUnsafeBytes { raw in var offset=0;while offset<raw.count {let n=write(fd,raw.baseAddress!.advanced(by:offset),raw.count-offset);if n<0 && errno==EINTR{continue};guard n>0 else{throw Self.failure()};offset+=n} }
        guard fsync(fd)==0 else{throw Self.failure()}
    }
    private func store(name:String,data:Data)throws->Row {
        _ = try WordPackage(data:data)
        let token=UUID().uuidString.lowercased()
        let row=try Self.validateReference(["kind":"word","token":token,"name":name,"bytes":data.count])
        let dir=try folder();defer{close(dir)}
        let current=try usage(dir)
        var record=row;record["sha256"]=SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()
        let metadata=try JSONSerialization.data(withJSONObject:record,options:[.sortedKeys])
        guard current.assets<Self.maximumAssets,current.bytes+data.count+metadata.count<=Self.maximumCacheBytes else{throw Self.failure("Word cache totals 512 MiB or 128 Word documents. Existing Word documents have been retained.")}
        let part=token+".part.docx",metaPart=token+".metadata.part"
        defer{_ = unlinkat(dir,part,0);_ = unlinkat(dir,metaPart,0)}
        try writeFile(dir,name:part,data:data);try writeFile(dir,name:metaPart,data:metadata)
        guard renameat(dir,part,dir,token+".docx")==0,renameat(dir,metaPart,dir,token+".json")==0,fsync(dir)==0 else{throw Self.failure()}
        return row
    }
    func reference(_ row:Row,verifyContent:Bool = true)throws->URL {
        let safe=try Self.validateReference(row),token=safe["token"] as! String
        let dir=try folder();defer{close(dir)}
        let (meta,_)=try checkedFile(dir,token+".json",maximum:2048);defer{close(meta)}
        let metadata=try Self.readBounded(meta,maximum:2048)
        guard let record=try JSONSerialization.jsonObject(with:metadata) as? Row,NSDictionary(dictionary:try Self.validateReference(record)).isEqual(to:safe),let expected=record["sha256"] as? String,expected.range(of:"^[a-f0-9]{64}$",options:.regularExpression) != nil else{throw Self.failure()}
        let (fd,info)=try checkedFile(dir,token+".docx",maximum:Self.maximumBytes);defer{close(fd)}
        guard Int(info.st_size)==safe["bytes"] as? Int else{throw Self.failure()}
        if verifyContent {
            let data=try Self.readBounded(fd,maximum:Self.maximumBytes);var after=stat(),named=stat()
            guard data.count==info.st_size,fstat(fd,&after)==0,fstatat(dir,token+".docx",&named,AT_SYMLINK_NOFOLLOW)==0,Self.unchanged(info,after),Self.unchanged(info,named),SHA256.hash(data:data).map({String(format:"%02x",$0)}).joined()==expected else{throw Self.failure()}
        }
        return directory.appendingPathComponent(token+".docx")
    }
}
