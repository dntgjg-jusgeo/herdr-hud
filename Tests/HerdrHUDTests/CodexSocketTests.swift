import XCTest
import Foundation
@testable import HerdrHUD

final class CodexSocketTests:XCTestCase {
    final class Fixture {
        let folder:URL,socket:String,process:Process
        init(mode:String="echo")throws {
            folder=URL(fileURLWithPath:"/private/tmp").appendingPathComponent("hudws-"+UUID().uuidString.prefix(8))
            try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            socket=folder.appendingPathComponent("ws").path
            let script=folder.appendingPathComponent("server.py")
            try Data(Self.program.utf8).write(to:script)
            process=Process();process.executableURL=URL(fileURLWithPath:"/usr/bin/python3");process.arguments=[script.path,socket,mode]
            process.standardOutput=FileHandle.nullDevice;process.standardError=FileHandle.nullDevice
            try process.run()
            for _ in 0..<150 {if FileManager.default.fileExists(atPath:socket){return};Thread.sleep(forTimeInterval:0.02)}
            throw HUDError("Synthetic socket fixture did not start.")
        }
        deinit {
            if process.isRunning {process.terminate();for _ in 0..<50 {if !process.isRunning{break};Thread.sleep(forTimeInterval:0.02)};if process.isRunning{kill(process.processIdentifier,SIGKILL)}}
            process.waitUntilExit();try? FileManager.default.removeItem(at:folder)
        }
        static let program = #"""
        import socket,sys,os,hashlib,base64,json,struct
        path,mode=sys.argv[1:]
        srv=socket.socket(socket.AF_UNIX);srv.bind(path);os.chmod(path,0o600);srv.listen(1)
        c,_=srv.accept();c.settimeout(12)
        def exact(n):
            out=b''
            while len(out)<n:
                b=c.recv(n-len(out))
                if not b: raise EOFError()
                out+=b
            return out
        h=b''
        while not h.endswith(b'\r\n\r\n'):h+=exact(1)
        headers=dict(line.split(b':',1) for line in h.split(b'\r\n')[1:] if b':' in line)
        key=headers[b'Sec-WebSocket-Key'].strip()
        accept=base64.b64encode(hashlib.sha1(key+b'258EAFA5-E914-47DA-95CA-C5AB0DC85B11').digest())
        if mode=='bad-handshake':accept=b'wrong'
        c.sendall(b'HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: '+accept+b'\r\n\r\n')
        def send(data,op=1,fin=True):
            if isinstance(data,dict):data=json.dumps(data).encode()
            n=len(data);head=bytes([(0x80 if fin else 0)|op,n]) if n<126 else bytes([(0x80 if fin else 0)|op,126])+struct.pack('!H',n)
            c.sendall(head+data)
        def read():
            a,b=exact(2);assert b&128
            n=b&127
            if n==126:n=struct.unpack('!H',exact(2))[0]
            if n==127:n=struct.unpack('!Q',exact(8))[0]
            mask=exact(4);data=exact(n);data=bytes(x^mask[i%4] for i,x in enumerate(data))
            return a&15,data
        if mode=='nonminimal':c.sendall(b'\x81\x7e\x00\x02{}')
        elif mode=='rsv':c.sendall(b'\xC1\x02{}')
        elif mode=='opcode':c.sendall(b'\x83\x02{}')
        elif mode=='control-fragment':c.sendall(b'\x09\x01x')
        elif mode=='control-large':send(b'x'*126,op=9)
        elif mode=='aggregate':
            send(b'x'*60000,fin=False)
            for _ in range(18):send(b'x'*60000,op=0,fin=False)
        elif mode=='utf16':send('{}'.encode('utf-16'))
        elif mode=='masked':c.sendall(b'\x81\x82'+b'0000'+b'AA')
        elif mode=='echo':
            op,data=read();assert op==1 and json.loads(data)=={'hello':'world'}
            send(b'check',op=9);send(b'{"value":"',fin=False);send(b'x'*200+b'"}',op=0)
            op,data=read();assert op==10 and data==b'check'
        elif mode in ('steer','steer-disconnect'):
            while True:
                op,data=read()
                if op==10:continue
                row=json.loads(data);method=row.get('method')
                if method=='initialize':send({'id':row['id'],'result':{}})
                elif method=='thread/loaded/list':send({'id':row['id'],'result':{'data':['thread-A']}})
                elif method=='thread/resume':send({'id':row['id'],'result':{'thread':{'id':'thread-A','status':{'type':'active','activeFlags':[]}}}})
                elif method=='thread/turns/list':send({'id':row['id'],'result':{'data':[{'id':'active-A','status':'inProgress'}]}})
                elif method=='turn/steer':
                    p=row['params'];assert p['threadId']=='thread-A' and p['expectedTurnId']=='active-A' and p['clientUserMessageId']
                    assert p['input'][0]=={'type':'text','text':'Synthetic follow-up only'}
                    if mode=='steer-disconnect':c.close();break
                    assert len(p['input'])==2 and p['input'][1]['type']=='localImage'
                    with open(p['input'][1]['path'],'rb') as f:assert f.read(8)==bytes([137,80,78,71,13,10,26,10])
                    send({'id':row['id'],'result':{'turnId':'active-A'}})
                    send({'method':'turn/completed','params':{'threadId':'thread-A','turn':{'id':'active-A'}}})
        elif mode=='approvals':
            while True:
                op,data=read()
                if op==10:continue
                row=json.loads(data);method=row.get('method')
                if method=='initialize':send({'id':row['id'],'result':{}})
                elif method=='thread/loaded/list':send({'id':row['id'],'result':{'data':['thread-A']}})
                elif method=='thread/resume':
                    assert row['params']=={'threadId':'thread-A','excludeTurns':True}
                    send({'id':row['id'],'result':{'thread':{'id':'thread-A'}}})
                    send({'id':'original-request','method':'mcpServer/elicitation/request','params':{'threadId':'thread-A','turnId':'turn-A','serverName':'Fake tool','mode':'form','message':'Synthetic permission only','requestedSchema':{'type':'object','properties':{}},'_meta':{'codex_approval_kind':'mcp_tool_call','persist':['session']}}})
                elif 'result' in row:
                    assert row=={'id':'original-request','result':{'action':'accept','content':None,'_meta':{'persist':'session'}}}
                    send({'method':'serverRequest/resolved','params':{'threadId':'thread-A','requestId':'original-request'}})
        """#
    }
    func testRealUnixHandshakeMaskingPingAndFragmentedJSON()throws {
        let f=try Fixture(),socket=try CodexSocket(path:f.socket);defer{socket.close()}
        try socket.send(["hello":"world"])
        let row=try socket.receive(timeout:3)
        XCTAssertEqual(row?["value"] as? String,String(repeating:"x",count:200))
    }
    func testRefusesInvalidHandshakeAndFrames()throws {
        let bad=try Fixture(mode:"bad-handshake")
        XCTAssertThrowsError(try CodexSocket(path:bad.socket))
        for mode in ["masked","utf16","nonminimal","rsv","opcode","control-fragment","control-large","aggregate"] {
            let f=try Fixture(mode:mode),socket=try CodexSocket(path:f.socket)
            XCTAssertThrowsError(try socket.receive(timeout:3));socket.close()
        }
    }
}
