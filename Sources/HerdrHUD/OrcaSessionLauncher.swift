import Foundation
import Darwin
import CoreFoundation

/// Opt-in managed OpenCode sessions. Call on the serial native work queue.
/// HC receives only nonsecret file paths/roles; a private Python exec wrapper
/// reads Keychain after startup and puts credentials exclusively in child env.
final class OrcaSessionLauncher {
    typealias Create = (URL,String,String,String,String,String,Int) throws -> Int
    typealias Adapter = (URL,String,Int,String,String,String,String) throws -> OrcaOpenCode
    let client: HCClient, opencode: String, directory: URL
    private let credential: () throws -> String, approve: (Row) throws -> Row
    private let create: Create, makeAdapter: Adapter, choosePort: () throws -> Int, ownsListener: (Int,Int) throws -> Bool
    private let wait: () -> Void, onTerminalCreated: (String) -> Void
    private let attempts: Int
    private var deadline: TimeInterval?
    private var cache: [String:(String,OrcaOpenCode)] = [:]
    init(client: HCClient, opencode: String, directory: URL? = nil,
         credential: @escaping () throws -> String = OrcaModels.keychainToken,
         approve: @escaping (Row) throws -> Row = OrcaSessionLauncher.approvedModel,
         create: @escaping Create = { try OrcaOpenCode.create(endpoint:$0,password:$1,sessionID:$2,modelID:$3,directory:$4,providerID:$5,expectedServerPID:$6) },
         adapter: @escaping Adapter = { try OrcaOpenCode(endpoint:$0,password:$1,serverPID:$2,sessionID:$3,modelID:$4,directory:$5,providerID:$6) },
         port: @escaping () throws -> Int = OrcaSessionLauncher.freePort,
         listener: @escaping (Int,Int) throws -> Bool = OrcaSessionLauncher.ownedListener,
         wait: @escaping () -> Void = { Thread.sleep(forTimeInterval:0.1) }, attempts: Int = 600,
         onTerminalCreated: @escaping (String) -> Void = { _ in }) {
        self.client=client;self.opencode=opencode
        self.directory=directory ?? FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("Herdr HUD/OrcaOpenCode",isDirectory:true)
        self.credential=credential;self.approve=approve;self.create=create;makeAdapter=adapter;choosePort=port;ownsListener=listener
        self.wait=wait;self.attempts=attempts;self.onTerminalCreated=onTerminalCreated
    }
    private static func refused(_ message: String = "Managed OrcaRouter session is unavailable. Existing chats have not changed.") -> HUDError { HUDError(message) }
    private var canWait: Bool { ProcessInfo.processInfo.systemUptime < (deadline ?? .infinity) }
    private func integer(_ value: Any?) throws -> Int {
        guard let n=value as? NSNumber,CFGetTypeID(n) != CFBooleanGetTypeID(),n.doubleValue > 0,n.doubleValue <= Double(Int32.max),n.doubleValue.rounded(.down) == n.doubleValue else { throw Self.refused() };return n.intValue
    }
    private func same(_ a: Any?,_ b: Any?) -> Bool { encode(a ?? NSNull()) == encode(b ?? NSNull()) }
    private func core() throws -> String {
        let value=try client.rpc([("hello",["generation":1,"framed":false])])[0]
        guard let core=value["core"] as? Row,let id=core["id"] as? String,!id.isEmpty,value["generation"] as? Int == 1 else { throw Self.refused() };return id
    }
    private func terminal(_ id: String) throws -> Row { try client.rpc([("terminal.get",["terminal":id])])[0] }
    private func identity(_ terminal: Row) throws -> Row {
        guard let address=terminal["address"] as? String,address.range(of:"^t[0-9a-z]+$",options:.regularExpression) != nil,terminal["state"] as? String == "live",
              let created=terminal["created_ms"] as? NSNumber,CFGetTypeID(created) != CFBooleanGetTypeID(),created.doubleValue > 0,
              let foreground=terminal["foreground"] as? Row else { throw Self.refused() }
        return ["address":address,"created_ms":created,"pid":try integer(terminal["pid"]),"foreground_pid":try integer(foreground["pid"])]
    }
    private func matches(_ terminal: Row,_ expected: Row,nonce: String,role: String) -> Bool {
        guard let actual=try? identity(terminal),same(actual,expected),let labels=terminal["labels"] as? [String:String],
              labels["hud.orca.owner"] == nonce,labels["hud.orca.role"] == role else { return false };return true
    }
    private func arguments(_ role: String,endpoint: String,session: String,cwd: String,port: Int) -> [String] {
        role == "transport" ? [opencode,"serve","--hostname","127.0.0.1","--port",String(port)] : [opencode,"--server",endpoint,"--session",session,cwd]
    }
    private func ready(_ started: Row,nonce: String,role: String,core: String,expected: [String]) throws -> Row {
        guard let address=started["address"] as? String,!address.contains("/"),let created=started["created_ms"] as? NSNumber else { throw Self.refused() }
        let pid=try integer(started["pid"])
        for _ in 0..<attempts where canWait {
            guard try self.core() == core else { throw Self.refused() }
            let current=try terminal(address)
            guard current["state"] as? String == "live",same(current["created_ms"],created),try integer(current["pid"]) == pid,
                  let labels=current["labels"] as? [String:String],labels["hud.orca.owner"] == nonce,labels["hud.orca.role"] == role else { throw Self.refused() }
            if let foreground=current["foreground"] as? Row,let args=foreground["argv"] as? [String],args == expected,(try? identity(current)) != nil { return current }
            wait()
        }
        throw Self.refused("New OrcaRouter terminal is still starting. Inspect its new Herdr terminal before retrying.")
    }
    private func folderFD() throws -> Int32 {
        guard directory.path.hasPrefix("/") else { throw Self.refused() }
        var fd=open("/",O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);guard fd >= 0 else { throw Self.refused() }
        for component in directory.pathComponents where component != "/" {
            guard component != ".",component != ".." else { close(fd);throw Self.refused() }
            var next=openat(fd,component,O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if next < 0 && errno == ENOENT { guard mkdirat(fd,component,0o700) == 0 || errno == EEXIST else { close(fd);throw Self.refused() };next=openat(fd,component,O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
            close(fd);guard next >= 0 else { throw Self.refused() };fd=next
        }
        var info=stat();guard fstat(fd,&info) == 0,info.st_uid == geteuid(),fchmod(fd,0o700) == 0 else { close(fd);throw Self.refused() };return fd
    }
    private func childFD(_ root: Int32,_ name: String) throws -> Int32 {
        guard name.range(of:"^[a-f0-9]{16}$",options:.regularExpression) != nil else { throw Self.refused() }
        let fd=openat(root,name,O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);guard fd >= 0 else { throw Self.refused() }
        var info=stat();guard fstat(fd,&info) == 0,info.st_uid == geteuid(),info.st_mode & 0o077 == 0 else { close(fd);throw Self.refused() };return fd
    }
    private func write(_ bytes: Data,_ name: String,folder: Int32) throws {
        guard bytes.count <= 65_536 else { throw Self.refused() }
        let fd=openat(folder,name,O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,0o600);guard fd >= 0 else { throw Self.refused() };defer { close(fd) }
        guard fchmod(fd,0o600) == 0 else { throw Self.refused() }
        try bytes.withUnsafeBytes { data in var offset=0;while offset < data.count { let n=Darwin.write(fd,data.baseAddress!.advanced(by:offset),data.count-offset);if n < 0 && errno == EINTR { continue };guard n > 0 else { throw Self.refused() };offset += n } }
        guard fsync(fd) == 0 else { throw Self.refused() };_ = fsync(folder)
    }
    private func write(_ row: Row,_ name: String,folder: Int32) throws { try write(JSONSerialization.data(withJSONObject:row,options:[.sortedKeys]),name,folder:folder) }
    private func read(_ folder: Int32) throws -> Row? {
        let fd=openat(folder,"session.json",O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if fd < 0 { if errno == ENOENT { return nil };throw Self.refused() };defer { close(fd) }
        var info=stat();guard fstat(fd,&info) == 0,info.st_mode & S_IFMT == S_IFREG,info.st_uid == geteuid(),info.st_nlink == 1,info.st_mode & 0o077 == 0,info.st_size > 0,info.st_size <= 65_536 else { throw Self.refused() }
        var data=Data(),bytes=[UInt8](repeating:0,count:8192)
        while true { let n=Darwin.read(fd,&bytes,bytes.count);if n < 0 && errno == EINTR { continue };guard n >= 0 else { throw Self.refused() };if n == 0 { break };data.append(contentsOf:bytes.prefix(n));guard data.count <= 65_536 else { throw Self.refused() } }
        guard let row=try JSONSerialization.jsonObject(with:data) as? Row else { throw Self.refused() };return row
    }
    static func approvedModel(_ model: Row) throws -> Row {
        guard let id=model["id"] as? String,OrcaModels.validID(id),model["openAIChat"] as? Bool == true,
              let name=model["name"] as? String else { throw refused("Choose a currently approved OpenAI-compatible OrcaRouter model.") }
        var record:Row=["id":id,"name":name,"supported_endpoint_types":["openai"]]
        if model["tools"] as? Bool == true { record["supported_parameters"]=["tools"] }
        record["context_length"]=model["contextLength"];record["max_completion_tokens"]=model["outputLength"]
        let data=try JSONSerialization.data(withJSONObject:["data":[record]])
        let result=try OrcaModels.normalize(data,releases:OrcaModels.bundledReleases(),now:Date())
        guard let allowed=(result["models"] as? [Row])?.first,allowed["id"] as? String == id,
              allowed["releaseDate"] as? String == model["releaseDate"] as? String,allowed["releaseSource"] as? String == model["releaseSource"] as? String else { throw refused("This model is outside the approved provider or release-date policy. Refresh the catalog.") };return allowed
    }
    static func configuration(model: Row,providerID: String) throws -> Row {
        guard let id=model["id"] as? String,OrcaModels.validID(id),model["openAIChat"] as? Bool == true,
              providerID.range(of:"^herdr-orca-[a-f0-9]{32}$",options:.regularExpression) != nil else { throw refused() }
        let selected=providerID+"/"+id
        var entry:Row=["modelID":id,"name":model["name"] as? String ?? id,"releaseDate":model["releaseDate"] ?? ""]
        var limits:Row=[:];if let value=model["contextLength"] { limits["context"]=value };if let value=model["outputLength"] { limits["output"]=value };if !limits.isEmpty { entry["limit"]=limits }
        if model["tools"] as? Bool == true { entry["capabilities"]=["tools":true] }
        return ["model":selected,"warming":false,"share":"disabled","media":["image":["auto_resize":false]],
            "providers":[providerID:["package":"@opencode/ai/providers/openai-compatible","settings":["baseURL":"https://api.orcarouter.ai/v1","apiKey":"{env:ORCAROUTER_API_KEY}"],"models":[id:entry]]],
            "agents":["title":["model":selected],"compaction":["model":selected]],
            "policies":[["action":"provider.use","resource":"*","effect":"deny"],["action":"provider.use","resource":providerID,"effect":"allow"]]]
    }
    func launch(directory path: String,model input: Row) throws -> Row {
        guard deadline == nil else { throw Self.refused() };deadline=ProcessInfo.processInfo.systemUptime+60;defer { deadline=nil }
        guard path.hasPrefix("/"),path.rangeOfCharacter(from:.controlCharacters) == nil,opencode.hasPrefix("/"),FileManager.default.isExecutableFile(atPath:opencode) else { throw Self.refused() }
        let cwd=URL(fileURLWithPath:path,isDirectory:true).resolvingSymlinksInPath().path;var cwdInfo=stat();guard stat(cwd,&cwdInfo) == 0,cwdInfo.st_mode & S_IFMT == S_IFDIR else { throw Self.refused() }
        let model=try approve(input),modelID=model["id"] as! String
        let port=try choosePort();guard (1024...65535).contains(port) else { throw Self.refused() }
        let nonce=UUID().uuidString.lowercased(),name=String(nonce.replacingOccurrences(of:"-",with:"").prefix(16)),session="ses"+UUID().uuidString.replacingOccurrences(of:"-",with:"").lowercased()
        let providerID="herdr-orca-"+nonce.replacingOccurrences(of:"-",with:""),config=try Self.configuration(model:model,providerID:providerID)
        let endpoint="http://127.0.0.1:\(port)",url=URL(string:endpoint)!,core=try self.core(),root=try folderFD();defer { close(root) }
        guard mkdirat(root,name,0o700) == 0 else { throw Self.refused() };let folder=try childFD(root,name);defer { close(folder) }
        let home=directory.appendingPathComponent(name,isDirectory:true),script=home.appendingPathComponent("launch.py").path
        try write(["opencode":opencode,"directory":cwd,"port":port,"nonce":nonce,"sessionID":session,"config":config],"launch.json",folder:folder)
        try write(Data(Self.startupScript.utf8),"launch.py",folder:folder)
        var server:Row?,tuiAttempted=false,tuiAddress:String?
        do {
            let started=try client.rpc([("terminal.run",["argv":["/usr/bin/python3",script,"serve"],"cwd":cwd,"labels":["hud.orca.owner":nonce,"hud.orca.role":"transport"],"no_parent":true,"no_notify":true,"outlive_parent":true])],mutation:true)[0]
            server=try ready(started,nonce:nonce,role:"transport",core:core,expected:arguments("transport",endpoint:endpoint,session:session,cwd:cwd,port:port))
            let serverIdentity=try identity(server!),pid=try integer(serverIdentity["foreground_pid"])
            var listening=false;for _ in 0..<attempts where canWait { if try ownsListener(pid,port) { listening=true;break };wait() };guard listening else { throw Self.refused("New OpenCode server has not opened its owned loopback listener.") }
            let password=try OrcaOpenCode.password(token:credential(),nonce:nonce)
            guard try create(url,password,session,modelID,cwd,providerID,pid) == pid,try self.core() == core,matches(try terminal(server!["address"] as! String),serverIdentity,nonce:nonce,role:"transport") else { throw Self.refused() }
            let partial:Row=["version":1,"folder":name,"nonce":nonce,"port":port,"endpoint":endpoint,"sessionID":session,"serverPID":pid,"modelID":modelID,"providerID":providerID,"directory":cwd,"coreID":core,"server":serverIdentity,"opencode":opencode]
            try write(partial,"pending.json",folder:folder);tuiAttempted=true
            let startedTUI=try client.rpc([("terminal.run",["argv":["/usr/bin/python3",script,"tui"],"cwd":cwd,"labels":["hud.orca.owner":nonce,"hud.orca.role":"tui"],"no_parent":true,"no_notify":true,"outlive_parent":true])],mutation:true)[0]
            let tui=try ready(startedTUI,nonce:nonce,role:"tui",core:core,expected:arguments("tui",endpoint:endpoint,session:session,cwd:cwd,port:port));tuiAddress=tui["address"] as? String
            if let address=tuiAddress { onTerminalCreated(address) }
            guard let row=try HCClient.row(tui,core:core,machines:[]),let id=row["id"] as? String,try ownsListener(pid,port) else { throw Self.refused() }
            var descriptor=partial;descriptor["tui"]=try identity(tui);descriptor["agentID"]=id
            try write(descriptor,"session.json",folder:folder);_ = unlinkat(folder,"pending.json",0)
            return ["agent":row,"descriptor":descriptor,"terminalID":tuiAddress!,"model":modelID]
        } catch {
            if !tuiAttempted,let server=server,let address=server["address"] as? String,let expected=try? identity(server),(try? self.core()) == core,let live=try? terminal(address),matches(live,expected,nonce:nonce,role:"transport") { _ = try? client.rpc([("terminal.kill",["terminal":address])],mutation:true) }
            throw Self.refused(tuiAttempted ? "New OrcaRouter setup is incomplete or uncertain. Inspect new OpenCode terminal \(tuiAddress ?? "(not confirmed)") before retrying; existing chats were not changed." : "New OrcaRouter setup failed before opening its TUI. Inspect any new background transport before retrying; existing chats were not changed.")
        }
    }
    func binding(for row: Row) throws -> Row? {
        guard row["machine_id"] as? String == "local",let id=row["id"] as? String else { return nil }
        let root=try folderFD();defer { close(root) }
        let names=try FileManager.default.contentsOfDirectory(atPath:directory.path).filter { $0.range(of:"^[a-f0-9]{16}$",options:.regularExpression) != nil };guard names.count <= 128 else { throw Self.refused() }
        for name in names {
            let folder=try childFD(root,name);defer { close(folder) };guard let value=try read(folder),value["agentID"] as? String == id else { continue }
            guard value["version"] as? Int == 1,value["folder"] as? String == name,let nonce=value["nonce"] as? String,UUID(uuidString:nonce) != nil,
                  let endpoint=value["endpoint"] as? String,let url=URL(string:endpoint),OrcaOpenCode.validEndpoint(url),
                  let session=value["sessionID"] as? String,session.range(of:"^ses[A-Za-z0-9_-]+$",options:.regularExpression) != nil,
                  let model=value["modelID"] as? String,OrcaModels.validID(model),
                  value["providerID"] as? String == "herdr-orca-"+nonce.replacingOccurrences(of:"-",with:""),let cwd=value["directory"] as? String,cwd.hasPrefix("/"),
                  value["opencode"] as? String == opencode,let core=value["coreID"] as? String,try self.core() == core,
                  let server=value["server"] as? Row,let tui=value["tui"] as? Row,let serverID=server["address"] as? String,let tuiID=tui["address"] as? String else { throw Self.refused() }
            let port=try integer(value["port"]),pid=try integer(value["serverPID"])
            guard url.port == port,try integer(server["foreground_pid"]) == pid else { throw Self.refused() }
            let liveServer=try terminal(serverID),liveTUI=try terminal(tuiID)
            guard matches(liveServer,server,nonce:nonce,role:"transport"),matches(liveTUI,tui,nonce:nonce,role:"tui"),
                  (liveServer["foreground"] as? Row)?["argv"] as? [String] == arguments("transport",endpoint:endpoint,session:session,cwd:cwd,port:port),
                  (liveTUI["foreground"] as? Row)?["argv"] as? [String] == arguments("tui",endpoint:endpoint,session:session,cwd:cwd,port:port),
                  let current=try HCClient.row(liveTUI,core:core,machines:[]),current["id"] as? String == id,
                  try ownsListener(pid,port) else { throw Self.refused("This managed OpenCode server or terminal changed. Use its terminal before reconnecting.") }
            return value
        }
        return nil
    }
    func adapter(for row: Row) throws -> OrcaOpenCode? {
        guard let binding=try binding(for:row),let id=row["id"] as? String else { return nil }
        let fingerprint=encode(binding)
        if let cached=cache[id] { guard cached.0 == fingerprint else { throw Self.refused("Managed OpenCode binding changed. Refresh before reconnecting.") };return cached.1 }
        guard let endpoint=binding["endpoint"] as? String,let url=URL(string:endpoint),let nonce=binding["nonce"] as? String,
              let session=binding["sessionID"] as? String,let model=binding["modelID"] as? String,let provider=binding["providerID"] as? String,let cwd=binding["directory"] as? String else { throw Self.refused() }
        let password=try OrcaOpenCode.password(token:credential(),nonce:nonce)
        let adapter=try makeAdapter(url,password,integer(binding["serverPID"]),session,model,cwd,provider)
        _ = try adapter.snapshot();cache[id]=(fingerprint,adapter);return adapter
    }
    static func ownedListener(pid: Int,port: Int) throws -> Bool {
        guard pid > 0,(1024...65535).contains(port) else { return false }
        let raw: String
        do { raw=try ProcessRunner(timeout:2).run(Invocation(executable:"/usr/sbin/lsof",arguments:["-nP","-a","-p",String(pid),"-u",String(geteuid()),"-iTCP:"+String(port),"-sTCP:LISTEN","-Fpn"],mutation:false)) } catch { return false }
        return listenerOutput(raw,pid:pid,port:port)
    }
    static func listenerOutput(_ raw: String,pid: Int,port: Int) -> Bool {
        let fields=raw.split(separator:"\n").map(String.init),processes=fields.filter { $0.hasPrefix("p") },addresses=fields.filter { $0.hasPrefix("n") }
        return processes == ["p"+String(pid)] && !addresses.isEmpty && addresses.allSatisfy { $0 == "n127.0.0.1:"+String(port) }
    }
    static func freePort() throws -> Int {
        let fd=socket(AF_INET,SOCK_STREAM,0);guard fd >= 0 else { throw refused() };defer { close(fd) }
        var address=sockaddr_in();address.sin_len=UInt8(MemoryLayout<sockaddr_in>.size);address.sin_family=sa_family_t(AF_INET);address.sin_addr=in_addr(s_addr:inet_addr("127.0.0.1"));address.sin_port=0
        guard withUnsafePointer(to:&address,{ $0.withMemoryRebound(to:sockaddr.self,capacity:1) { Darwin.bind(fd,$0,socklen_t(MemoryLayout<sockaddr_in>.size)) } }) == 0 else { throw refused() }
        var size=socklen_t(MemoryLayout<sockaddr_in>.size)
        guard withUnsafeMutablePointer(to:&address,{ $0.withMemoryRebound(to:sockaddr.self,capacity:1) { getsockname(fd,$0,&size) } }) == 0 else { throw refused() };return Int(UInt16(bigEndian:address.sin_port))
    }
    static let startupScript = #"""
import hashlib, hmac, json, os, pathlib, pwd, subprocess, sys
base = pathlib.Path(__file__).parent
try:
    spec = json.loads((base / 'launch.json').read_text())
    if len(sys.argv) != 2 or sys.argv[1] not in ('serve', 'tui'):
        raise ValueError()
    result = subprocess.run(['/usr/bin/security', 'find-generic-password', '-a', pwd.getpwuid(os.geteuid()).pw_name,
                             '-s', 'ORCAROUTER_AUTH_TOKEN', '-w'], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=8)
    token = result.stdout.rstrip(b'\r\n')
    if result.returncode or not token or len(token) > 8192 or any(c <= 32 or c == 127 for c in token):
        raise ValueError()
    env = dict(os.environ)
    env['ORCAROUTER_API_KEY'] = token.decode('utf-8')
    env['OPENCODE_PASSWORD'] = hmac.new(token, ('herdr-hud/opencode/v1/' + spec['nonce']).encode(), hashlib.sha256).hexdigest()
    env['OPENCODE_CONFIG_CONTENT'] = json.dumps(spec['config'])
    env['OPENCODE_DISABLE_FREE_MODELS'] = '1'
    env['OPENCODE_DISABLE_MODELS_FETCH'] = '1'
    # Keep the user's XDG_CONFIG_HOME/permissions; only runtime/session data is isolated.
    for kind in ('DATA', 'CACHE', 'STATE'):
        path = base / kind.lower()
        path.mkdir(mode=0o700, exist_ok=True)
        env['XDG_' + kind + '_HOME'] = str(path)
    # The transport terminal is not the model's conversational terminal.
    for marker in ('HC_TERMINAL_ID', 'HC_TERMINAL_SOCKET'):
        env.pop(marker, None)
    endpoint = 'http://127.0.0.1:' + str(spec['port'])
    args = [spec['opencode']]
    if sys.argv[1] == 'serve':
        args += ['serve', '--hostname', '127.0.0.1', '--port', str(spec['port'])]
    else:
        args += ['--server', endpoint, '--session', spec['sessionID'], spec['directory']]
    os.chdir(spec['directory'])
    os.execve(spec['opencode'], args, env)
except Exception:
    sys.stderr.write('Managed OrcaRouter startup failed; check Keychain access or the new terminal.\n')
    sys.exit(1)
"""#
}
