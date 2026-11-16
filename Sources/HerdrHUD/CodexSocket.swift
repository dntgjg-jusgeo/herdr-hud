import Foundation
import Darwin
import CryptoKit

/// Codex's local transport is WebSocket over a private Unix socket, not JSONL.
/// One worker owns this connection. There is no TCP listener or credential copy.
final class CodexSocket {
    private var fd:Int32 = -1
    private var buffer=Data(), fragments=Data()
    private var fragmenting=false
    static let limit=1_048_576
    private static var now:Double { ProcessInfo.processInfo.systemUptime }
    init(path:String) throws {
        guard path.hasPrefix("/"),!path.contains("\0"),path.utf8.count<104 else { throw HUDError("Invalid local Codex socket path.") }
        var info=stat()
        guard lstat(path,&info)==0,(info.st_mode & S_IFMT)==S_IFSOCK,info.st_uid==geteuid(),(info.st_mode & 0o077)==0 else { throw HUDError("Codex approval socket is unavailable or not private.") }
        fd=socket(AF_UNIX,SOCK_STREAM,0)
        guard fd>=0 else { throw HUDError("Could not open local Codex connection.") }
        do {
            guard fcntl(fd,F_SETFD,FD_CLOEXEC)==0,fcntl(fd,F_SETFL,O_NONBLOCK)==0 else { throw HUDError("Could not configure local Codex socket deadlines.") }
            var yes:Int32=1;guard setsockopt(fd,SOL_SOCKET,SO_NOSIGPIPE,&yes,socklen_t(MemoryLayout<Int32>.size))==0 else { throw HUDError("Could not configure local Codex connection.") }
            var address=sockaddr_un();address.sun_family=sa_family_t(AF_UNIX);address.sun_len=UInt8(MemoryLayout<sockaddr_un>.size)
            withUnsafeMutableBytes(of:&address.sun_path){target in
                target.initializeMemory(as:UInt8.self,repeating:0)
                _=path.utf8CString.withUnsafeBytes { source in memcpy(target.baseAddress!,source.baseAddress!,source.count) }
            }
            let result=withUnsafePointer(to:&address) { $0.withMemoryRebound(to:sockaddr.self,capacity:1){Darwin.connect(fd,$0,socklen_t(MemoryLayout<sockaddr_un>.size))} }
            if result != 0 {
                guard errno==EINPROGRESS,try wait(POLLOUT,until:Self.now+5) else { throw HUDError("Could not connect to the local Codex server.") }
                var error:Int32=0,size=socklen_t(MemoryLayout<Int32>.size)
                guard getsockopt(fd,SOL_SOCKET,SO_ERROR,&error,&size)==0,error==0 else { throw HUDError("Could not connect to the local Codex server.") }
            }
            var uid:uid_t=0,gid:gid_t=0
            guard getpeereid(fd,&uid,&gid)==0,uid==geteuid() else { throw HUDError("Codex socket belongs to another account.") }
            try handshake()
        } catch { close();throw error }
    }
    deinit { close() }
    func close(){if fd>=0 {_=Darwin.close(fd);fd = -1}}
    private func wait(_ events:Int32,until deadline:Double)throws->Bool {
        while Self.now<deadline {
            guard fd>=0 else { throw HUDError("Codex connection is closed.") }
            var p=pollfd(fd:fd,events:Int16(events),revents:0)
            let result=poll(&p,1,Int32(max(1,min(1000,(deadline-Self.now)*1000))))
            if result>0 {guard p.revents & Int16(POLLNVAL)==0 else{throw HUDError("Codex connection failed.")};return true}
            if result<0 && errno != EINTR {throw HUDError("Codex connection failed.")}
        }
        return false
    }
    private func write(_ bytes:Data,until deadline:Double)throws {
        var offset=0
        while offset<bytes.count {
            guard try wait(POLLOUT,until:deadline) else {throw HUDError("Codex response delivery uncertain: local write timed out.")}
            let n=bytes.withUnsafeBytes{Darwin.write(fd,$0.baseAddress!.advanced(by:offset),bytes.count-offset)}
            if n>0 {offset+=n}
            else if n==0 || (errno != EAGAIN && errno != EINTR) {throw HUDError("Codex response delivery uncertain: connection closed.")}
        }
    }
    private func read(until deadline:Double)throws->Bool {
        guard try wait(POLLIN,until:deadline) else {return false}
        var bytes=[UInt8](repeating:0,count:16_384)
        let n=Darwin.read(fd,&bytes,bytes.count)
        if n>0 {buffer.append(contentsOf:bytes.prefix(n));guard buffer.count<=Self.limit+16_384 else{throw HUDError("Codex message exceeds its limit.")};return true}
        if n<0 && (errno==EINTR || errno==EAGAIN) {return false}
        throw HUDError("Codex approval connection closed. Inspect its terminal before continuing.")
    }
    private func handshake()throws {
        let key=Data((0..<16).map{_ in UInt8.random(in:0...255)}).base64EncodedString()
        let request="GET / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: "+key+"\r\nSec-WebSocket-Version: 13\r\n\r\n"
        let deadline=Self.now+5;try write(Data(request.utf8),until:deadline)
        let marker=Data("\r\n\r\n".utf8)
        while buffer.range(of:marker)==nil {
            guard buffer.count<=16_384,try read(until:deadline) else {throw HUDError("Codex WebSocket handshake timed out.")}
        }
        let end=buffer.range(of:marker)!.upperBound
        guard end<=16_384,let header=String(data:buffer.prefix(end),encoding:.utf8) else {throw HUDError("Invalid Codex WebSocket handshake.")}
        buffer.removeFirst(end)
        let lines=header.components(separatedBy:"\r\n"),status=lines[0].split(separator:" ")
        guard status.count>=2,status[0]=="HTTP/1.1",status[1]=="101" else{throw HUDError("Codex refused its local WebSocket connection.")}
        var headers:[String:String]=[:]
        for line in lines.dropFirst() where !line.isEmpty {
            guard let colon=line.firstIndex(of:":") else {throw HUDError("Invalid Codex WebSocket headers.")}
            let name=line[..<colon].lowercased(),value=line[line.index(after:colon)...].trimmingCharacters(in:.whitespaces)
            guard headers[name]==nil else {throw HUDError("Duplicate Codex WebSocket headers.")};headers[name]=value
        }
        let digest=Insecure.SHA1.hash(data:Data((key+"258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))
        guard headers["sec-websocket-accept"]==Data(digest).base64EncodedString(),
              headers["upgrade"]?.lowercased()=="websocket",
              headers["connection"]?.lowercased().split(separator:",").map({$0.trimmingCharacters(in:.whitespaces)}).contains("upgrade")==true,
              headers["sec-websocket-extensions"]==nil,headers["sec-websocket-protocol"]==nil else {throw HUDError("Invalid Codex WebSocket upgrade.")}
    }
    private func frame(_ payload:Data,opcode:UInt8)throws {
        guard payload.count<=Self.limit else {throw HUDError("Codex response exceeds its limit.")}
        var bytes=Data([0x80|opcode])
        if payload.count<126 {bytes.append(0x80|UInt8(payload.count))}
        else if payload.count<=65_535 {bytes.append(0x80|126);bytes.append(UInt8(payload.count>>8));bytes.append(UInt8(payload.count&255))}
        else {bytes.append(0x80|127);let count=UInt64(payload.count);for shift in stride(from:56,through:0,by:-8){bytes.append(UInt8((count>>shift)&255))}}
        let mask=(0..<4).map{_ in UInt8.random(in:0...255)};bytes.append(contentsOf:mask)
        bytes.append(contentsOf:payload.enumerated().map{$0.element ^ mask[$0.offset%4]})
        try write(bytes,until:Self.now+5)
    }
    func send(_ row:Row)throws {try frame(JSONSerialization.data(withJSONObject:row,options:[.sortedKeys]),opcode:1)}
    func receive(timeout:TimeInterval)throws->Row? {
        let deadline=Self.now+max(0.001,timeout)
        while true {
            if buffer.count>=2 {
                // Normalize indices after removeFirst: Data slices need not start at zero.
                let bytes=Array(buffer.prefix(10)),fin=bytes[0]&0x80 != 0,opcode=bytes[0]&0x0f
                guard bytes[0]&0x70==0,bytes[1]&0x80==0,[0,1,8,9,10].contains(opcode) else{throw HUDError("Unsupported Codex WebSocket frame.")}
                let short=Int(bytes[1]&0x7f),header=short==126 ? 4:short==127 ? 10:2
                if buffer.count>=header {
                    var length=UInt64(short)
                    if short>=126 {length=0;for byte in bytes[2..<header]{length=(length<<8)|UInt64(byte)}}
                    guard (short != 126 || length>=126),(short != 127 || length>65_535),length<=Self.limit else{throw HUDError("Codex message exceeds its limit.")}
                    guard opcode<8 || (fin && length<=125) else{throw HUDError("Invalid Codex WebSocket control frame.")}
                    if buffer.count>=header+Int(length) {
                        let payload=Data(buffer.dropFirst(header).prefix(Int(length)));buffer.removeFirst(header+Int(length))
                        if opcode==8 {throw HUDError("Codex approval connection closed. Inspect its terminal before continuing.")}
                        if opcode==9 {try frame(payload,opcode:10)}
                        else if opcode==10 {}
                        else {
                            guard (opcode==0 && fragmenting)||(opcode==1 && !fragmenting) else{throw HUDError("Invalid Codex message fragmentation.")}
                            fragments.append(payload);guard fragments.count<=Self.limit else{throw HUDError("Codex message exceeds its limit.")}
                            fragmenting = !fin
                            if fin {
                                let data=fragments;fragments.removeAll(keepingCapacity:true)
                                guard String(data:data,encoding:.utf8) != nil,let row=try JSONSerialization.jsonObject(with:data) as? Row else{throw HUDError("Invalid Codex approval message.")}
                                return row
                            }
                        }
                        if Self.now>=deadline{return nil};continue
                    }
                }
            }
            guard try read(until:deadline) else{return nil}
        }
    }
}
