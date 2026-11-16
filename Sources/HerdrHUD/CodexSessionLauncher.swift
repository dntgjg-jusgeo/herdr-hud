import Foundation
import Darwin
import CoreFoundation
import CryptoKit

/// Creates NEW opt-in native sessions. Existing terminals are never adopted or resumed.
/// Call on the HUD's serial work queue. No turn or prompt is sent by this launcher.
final class CodexSessionLauncher {
    static let model = "gpt-6-astra", effort = "medium"
    let client: HCClient
    let codex: String
    let directory: URL
    private let query: (String, String, Row) throws -> Row
    private let wait: () -> Void
    private let readinessAttempts: Int
    private let onTerminalCreated: (String) -> Void
    private var launchDeadline: TimeInterval?
    private var canWait: Bool { ProcessInfo.processInfo.systemUptime < (launchDeadline ?? .infinity) }

    init(client: HCClient, codex: String, directory: URL? = nil,
         query: ((String, String, Row) throws -> Row)? = nil,
         wait: @escaping () -> Void = { Thread.sleep(forTimeInterval: 0.05) }, readinessAttempts: Int = 1200,
         onTerminalCreated: @escaping (String) -> Void = { _ in }) {
        self.client = client; self.codex = codex
        self.directory = directory ?? FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0]
            .appendingPathComponent("Herdr HUD/CodexSessions",isDirectory:true)
        self.query = query ?? { socket, method, params in try Self.nativeQuery(socket:socket,method:method,params:params) }
        self.wait = wait; self.readinessAttempts = readinessAttempts;self.onTerminalCreated = onTerminalCreated
    }
    private func failure(_ detail: String = "") -> HUDError {
        HUDError(detail.isEmpty ? "Native Codex session setup is unavailable. Existing sessions are unchanged." : detail)
    }
    private func positive(_ value: Any?) -> NSNumber? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue > 0,
              number.doubleValue.rounded(.down) == number.doubleValue else { return nil }; return number
    }
    private func same(_ a: Any?, _ b: Any?) -> Bool { encode(a ?? NSNull()) == encode(b ?? NSNull()) }
    private func coreID() throws -> String {
        let hello = try client.rpc([("hello",["generation":1,"framed":false])])[0]
        guard let generation = hello["generation"] as? NSNumber, generation.intValue == 1,
              let core = hello["core"] as? Row, let id = core["id"] as? String, !id.isEmpty else { throw failure() }
        return id
    }
    private func terminal(_ address: String) throws -> Row {
        try client.rpc([("terminal.get",["terminal":address])])[0]
    }
    private func identity(_ terminal: Row) throws -> Row {
        guard let address = terminal["address"] as? String, address.range(of:"^t[0-9a-z]+$",options:.regularExpression) != nil,
              terminal["state"] as? String == "live", let created = positive(terminal["created_ms"]),
              let pid = positive(terminal["pid"]), let foreground = terminal["foreground"] as? Row,
              let foregroundPID = positive(foreground["pid"]) else { throw failure() }
        return ["address":address,"created_ms":created,"pid":pid,"foreground_pid":foregroundPID]
    }
    private func matches(_ terminal: Row, identity: Row, owner: String, role: String) -> Bool {
        guard let current = try? self.identity(terminal), let labels = terminal["labels"] as? [String:String],
              labels["hud.codex.owner"] == owner, labels["hud.codex.role"] == role else { return false }
        return same(current,identity)
    }
    private func owned(_ result: Row, owner: String, role: String, core: String) throws -> Row {
        guard let address = result["address"] as? String, !address.contains("/"),
              let created = positive(result["created_ms"]), let pid = positive(result["pid"]) else { throw failure() }
        for _ in 0..<readinessAttempts where canWait {
            guard try coreID() == core else { throw failure() }
            let current = try terminal(address)
            guard same(current["created_ms"],created), same(current["pid"],pid), current["state"] as? String == "live",
                  let labels = current["labels"] as? [String:String], labels["hud.codex.owner"] == owner,
                  labels["hud.codex.role"] == role else { throw failure() }
            if (try? identity(current)) != nil { return current }
            wait()
        }
        throw failure("New Codex session is still starting. Inspect its new Herdr terminals before retrying.")
    }
    private func readyTUI(_ started: Row, owner: String, core: String, endpoint: String) throws -> (Row,Row) {
        let initial = try owned(started,owner:owner,role:"tui",core:core)
        let address = initial["address"] as! String
        var previousID: String?
        for _ in 0..<readinessAttempts where canWait {
            guard try coreID() == core else { throw failure() }
            let current = try terminal(address)
            guard same(current["created_ms"],initial["created_ms"]), same(current["pid"],initial["pid"]),
                  let labels = current["labels"] as? [String:String], labels["hud.codex.owner"] == owner, labels["hud.codex.role"] == "tui" else { throw failure() }
            if let foreground = current["foreground"] as? Row, let argv = foreground["argv"] as? [String],
               let remote = argv.firstIndex(of:"--remote"), argv.indices.contains(remote+1), argv[remote+1] == endpoint,
               !argv.contains("resume"),
               let status = current["status"] as? Row, status["app"] as? String == "codex",
               let row = try HCClient.row(current,core:core,machines:[]), row["agent"] as? String == "codex",
               row["agent_status"] as? String != "unknown", let id = row["id"] as? String {
                if previousID == id { return (current,row) };previousID = id
            } else { previousID = nil }
            wait()
        }
        throw failure("New Codex TUI has not reported a stable session identity. Inspect its new terminal before retrying.")
    }
    private func rootFD() throws -> Int32 {
        guard directory.path.hasPrefix("/") else { throw failure() }
        var fd = open("/",O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw failure() }
        for component in directory.pathComponents where component != "/" {
            guard component != ".", component != ".." else { close(fd);throw failure() }
            var next = openat(fd,component,O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if next < 0 && errno == ENOENT {
                guard mkdirat(fd,component,0o700) == 0 || errno == EEXIST else { close(fd);throw failure() }
                next = openat(fd,component,O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            close(fd);guard next >= 0 else { throw failure() };fd = next
        }
        var info = stat()
        guard fstat(fd,&info) == 0, info.st_uid == getuid(), fchmod(fd,0o700) == 0 else { close(fd);throw failure() }
        return fd
    }
    private func sessionFD(root: Int32, name: String) throws -> Int32 {
        guard name.range(of:"^[a-f0-9]{16}$",options:.regularExpression) != nil else { throw failure() }
        let fd = openat(root,name,O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw failure() }
        var info = stat()
        guard fstat(fd,&info) == 0, info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { close(fd);throw failure() }
        return fd
    }
    private func canonical(_ path: String) throws -> String {
        guard let pointer = realpath(path,nil) else { throw failure() };defer { free(pointer) };return String(cString:pointer)
    }
    private func socketIdentity(folder: Int32, alias: String) throws -> Row {
        var link = stat()
        guard fstatat(folder,"s",&link,AT_SYMLINK_NOFOLLOW) == 0, link.st_uid == geteuid() else { throw failure() }
        var physical = alias
        if link.st_mode & S_IFMT == S_IFLNK {
            // Official Codex rendezvous aliases point ONLY to the SHA256 of
            // canonical(parent)/filename in its fixed private daemon directory.
            let normalized = try canonical(URL(fileURLWithPath:alias).deletingLastPathComponent().path)+"/s"
            let hash = SHA256.hash(data:Data(normalized.utf8)).map { String(format:"%02x",$0) }.joined()
            let shared = try canonical("/tmp")+"/codex-daemon-\(geteuid())"
            var directoryInfo = stat()
            guard lstat(shared,&directoryInfo) == 0, directoryInfo.st_mode & S_IFMT == S_IFDIR,
                  directoryInfo.st_uid == geteuid(), directoryInfo.st_mode & 0o777 == 0o700 else { throw failure() }
            let expected = shared+"/"+hash
            var bytes = [UInt8](repeating:0,count:4096)
            let count = readlinkat(folder,"s",&bytes,bytes.count)
            guard count > 0, count < bytes.count, String(bytes:bytes.prefix(count),encoding:.utf8) == expected else { throw failure() }
            physical = expected
        } else if link.st_mode & S_IFMT != S_IFSOCK { throw failure() }
        var socket = stat()
        guard lstat(physical,&socket) == 0, socket.st_mode & S_IFMT == S_IFSOCK,
              socket.st_uid == geteuid(), socket.st_mode & 0o077 == 0 else { throw failure() }
        return ["path":physical,"device":NSNumber(value:UInt64(bitPattern:Int64(socket.st_dev))),"inode":NSNumber(value:UInt64(socket.st_ino)),
                "aliasDevice":NSNumber(value:UInt64(bitPattern:Int64(link.st_dev))),"aliasInode":NSNumber(value:UInt64(link.st_ino))]
    }
    private func write(_ value: Row, name: String, folder: Int32) throws {
        let bytes = try JSONSerialization.data(withJSONObject:value,options:[.sortedKeys])
        guard bytes.count <= 65_536 else { throw failure() }
        let fd = openat(folder,name,O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,0o600)
        guard fd >= 0 else { throw failure() };defer { close(fd) }
        guard fchmod(fd,0o600) == 0 else { throw failure() }
        try bytes.withUnsafeBytes { data in
            var offset = 0
            while offset < data.count {
                let n = Darwin.write(fd,data.baseAddress!.advanced(by:offset),data.count-offset)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw failure() };offset += n
            }
        }
        guard fsync(fd) == 0 else { throw failure() };_ = fsync(folder)
    }
    private func read(folder: Int32) throws -> Row? {
        let fd = openat(folder,"session.json",O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if fd < 0 { if errno == ENOENT { return nil };throw failure() };defer { close(fd) }
        var info = stat()
        guard fstat(fd,&info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_nlink == 1,
              info.st_mode & 0o077 == 0, info.st_size > 0, info.st_size <= 65_536 else { throw failure() }
        var data = Data(), buffer = [UInt8](repeating:0,count:8192)
        while true {
            let n = Darwin.read(fd,&buffer,buffer.count)
            if n < 0 && errno == EINTR { continue };guard n >= 0 else { throw failure() };if n == 0 { break }
            data.append(contentsOf:buffer.prefix(n));guard data.count <= 65_536 else { throw failure() }
        }
        guard let row = try JSONSerialization.jsonObject(with:data) as? Row else { throw failure() };return row
    }
    private func safeDirectory(_ path: String) throws -> String {
        guard path.hasPrefix("/"), !path.contains("\0"), !path.contains(where: { $0.isNewline }) else { throw failure() }
        let canonical = URL(fileURLWithPath:path,isDirectory:true).resolvingSymlinksInPath().path
        var info = stat();guard stat(canonical,&info) == 0, info.st_mode & S_IFMT == S_IFDIR else { throw failure() };return canonical
    }
    private func loaded(socket: String) throws -> [String] {
        let result = try query(socket,"thread/loaded/list",["limit":2])
        guard let ids = result["data"] as? [String], ids.count <= 1,
              result["nextCursor"] == nil || result["nextCursor"] is NSNull,
              ids.allSatisfy({ UUID(uuidString:$0) != nil }) else { throw failure("The new Codex transport contains ambiguous threads. Inspect its new TUI before retrying.") }
        return ids
    }
    func launch(directory path: String) throws -> Row {
        guard launchDeadline == nil else { throw failure() }
        launchDeadline = ProcessInfo.processInfo.systemUptime + 60;defer { launchDeadline = nil }
        let cwd = try safeDirectory(path)
        guard codex.hasPrefix("/"), !codex.contains("\0"), FileManager.default.isExecutableFile(atPath:codex) else { throw failure() }
        let root = try rootFD();defer { close(root) }
        let owner = UUID().uuidString.lowercased(), name = String(owner.replacingOccurrences(of:"-",with:"").prefix(16))
        let socket = directory.appendingPathComponent(name).appendingPathComponent("s").path
        guard socket.utf8.count < MemoryLayout.size(ofValue:sockaddr_un().sun_path) else { throw failure("Private Codex socket path is too long. Choose a shorter private session-storage path before launching.") }
        let core = try coreID(), endpoint = "unix://" + socket
        guard mkdirat(root,name,0o700) == 0 else { throw failure() }
        let folder = try sessionFD(root:root,name:name);defer { close(folder) }
        var server: Row?, tuiAttempted = false, tuiAddress: String?
        do {
            let started = try client.rpc([("terminal.run",["argv":[codex,"app-server","--listen",endpoint],"cwd":cwd,
                "labels":["hud.codex.owner":owner,"hud.codex.role":"transport"],"no_parent":true,"no_notify":true,"outlive_parent":true])],mutation:true)[0]
            server = try owned(started,owner:owner,role:"transport",core:core)
            var socketInfo: Row?
            for _ in 0..<readinessAttempts where canWait { if let value = try? socketIdentity(folder:folder,alias:socket) { socketInfo = value;break };wait() }
            guard let socketInfo = socketInfo else { throw failure() }
            guard let physicalSocket = socketInfo["path"] as? String,
                  try loaded(socket:physicalSocket).isEmpty, same(try socketIdentity(folder:folder,alias:socket),socketInfo),
                  try coreID() == core else { throw failure() }
            let currentServer = try terminal(server!["address"] as! String)
            guard same(currentServer["created_ms"],server!["created_ms"]), same(currentServer["pid"],server!["pid"]),
                  let serverLabels = currentServer["labels"] as? [String:String], serverLabels["hud.codex.owner"] == owner,
                  serverLabels["hud.codex.role"] == "transport", let serverArgv = (currentServer["foreground"] as? Row)?["argv"] as? [String],
                  serverArgv.contains("app-server"), serverArgv.contains(endpoint) else { throw failure() }
            server = currentServer
            var descriptor: Row = ["version":1,"owner":owner,"folder":name,"socket":physicalSocket,"socketAlias":socket,"socketInstance":socketInfo,
                "directory":cwd,"coreID":core,"server":try identity(server!),"model":Self.model,"reasoningEffort":Self.effort]
            try write(descriptor,name:"pending.json",folder:folder)
            tuiAttempted = true
            let startedTUI = try client.rpc([("terminal.run",["argv":[codex,"--remote",endpoint,"-m",Self.model,"-c","model_reasoning_effort=\"medium\""],
                "cwd":cwd,"labels":["hud.codex.owner":owner,"hud.codex.role":"tui"],"no_parent":true,"no_notify":true,"outlive_parent":true])],mutation:true)[0]
            let appeared = try owned(startedTUI,owner:owner,role:"tui",core:core)
            tuiAddress = appeared["address"] as? String
            if let address = tuiAddress { onTerminalCreated(address) }
            let (terminal,row) = try readyTUI(startedTUI,owner:owner,core:core,endpoint:endpoint)
            guard let id = row["id"] as? String, same(try socketIdentity(folder:folder,alias:socket),socketInfo) else { throw failure() }
            var threadID: String?
            for _ in 0..<readinessAttempts where canWait {
                let ids = try loaded(socket:physicalSocket)
                if let only = ids.first { threadID = only;break };wait()
            }
            guard let threadID = threadID, same(try socketIdentity(folder:folder,alias:socket),socketInfo) else { throw failure() }
            descriptor["threadID"] = threadID;descriptor["tui"] = try identity(terminal);descriptor["agentID"] = id
            try write(descriptor,name:"session.json",folder:folder)
            _ = unlinkat(folder,"pending.json",0)
            return ["descriptor":descriptor,"agent":row]
        } catch {
            // Before any TUI launch attempt, only this verified new server can
            // have been exposed, and no turn has been requested. Never kill after
            // TUI launch uncertainty: a person may already be interacting with it.
            if !tuiAttempted, let server = server, let address = server["address"] as? String,
               let expected = try? identity(server), (try? coreID()) == core,
               let current = try? terminal(address), matches(current,identity:expected,owner:owner,role:"transport") {
                _ = try? client.rpc([("terminal.kill",["terminal":address])],mutation:true)
            }
            throw failure(tuiAttempted ? "New Codex launch is incomplete or uncertain. Inspect new terminal \(tuiAddress ?? "(not yet confirmed)") in Herdr, finish any startup prompts, and refresh before retrying; existing sessions were not changed." : "New Codex setup failed before a TUI was launched. Existing sessions were not changed; inspect any newly created background transport before retrying.")
        }
    }
    func binding(for row: Row) throws -> Row? {
        guard row["machine_id"] as? String == "local", let rowID = row["id"] as? String else { return nil }
        let root = try rootFD();defer { close(root) }
        let names = try FileManager.default.contentsOfDirectory(atPath:directory.path).filter { $0.range(of:"^[a-f0-9]{16}$",options:.regularExpression) != nil }
        guard names.count <= 128 else { throw failure() }
        for name in names {
            let folder = try sessionFD(root:root,name:name);defer { close(folder) }
            guard let descriptor = try read(folder:folder), descriptor["agentID"] as? String == rowID else { continue }
            guard descriptor["version"] as? Int == 1, descriptor["folder"] as? String == name,
                  let owner = descriptor["owner"] as? String, UUID(uuidString:owner) != nil,
                  let thread = descriptor["threadID"] as? String, UUID(uuidString:thread) != nil,
                  let alias = descriptor["socketAlias"] as? String, alias == directory.appendingPathComponent(name).appendingPathComponent("s").path,
                  let socket = descriptor["socket"] as? String,
                  let core = descriptor["coreID"] as? String, try coreID() == core,
                  let server = descriptor["server"] as? Row, let tui = descriptor["tui"] as? Row,
                  let serverAddress = server["address"] as? String, let tuiAddress = tui["address"] as? String,
                  same(try socketIdentity(folder:folder,alias:alias),descriptor["socketInstance"]),
                  (descriptor["socketInstance"] as? Row)?["path"] as? String == socket,
                  matches(try terminal(serverAddress),identity:server,owner:owner,role:"transport") else { throw failure("This native Codex session was replaced or disconnected. Refresh before responding.") }
            let currentTUI = try terminal(tuiAddress)
            guard matches(currentTUI,identity:tui,owner:owner,role:"tui"),
                  let currentRow = try HCClient.row(currentTUI,core:core,machines:[]), currentRow["id"] as? String == rowID else {
                throw failure("This native Codex session identity changed. Refresh before responding.")
            }
            return descriptor
        }
        return nil
    }

    /// Native Unix app-server transport is WebSocket over UDS, not JSON lines.
    /// Bootstrap only discovers loaded thread IDs; the stock TUI creates its
    /// own NEW thread. The launcher never starts a turn or prompt.
    static func nativeQuery(socket: String, method: String, params: Row) throws -> Row {
        guard method == "thread/loaded/list" else { throw HUDError("Unsupported native session-discovery request.") }
        let transport = try CodexSocket(path:socket);defer { transport.close() }
        let initialize = "initialize-"+UUID().uuidString, start = "start-"+UUID().uuidString
        try transport.send(["id":initialize,"method":"initialize","params":["clientInfo":["name":"herdr_hud_launcher","title":"Herdr HUD","version":"1"],"capabilities":["experimentalApi":true]]])
        let deadline = ProcessInfo.processInfo.systemUptime + 12
        var stage = 0, messages = 0
        while ProcessInfo.processInfo.systemUptime < deadline {
            guard let message = try transport.receive(timeout:min(1,deadline-ProcessInfo.processInfo.systemUptime)) else { continue }
            messages += 1;guard messages <= 256 else { throw HUDError("Private Codex bootstrap exceeded its response limit.") }
            if stage == 0 && message["id"] as? String == initialize {
                guard message["error"] == nil, message["result"] is Row else { throw HUDError("Private Codex initialization was refused.") }
                try transport.send(["method":"initialized"])
                try transport.send(["id":start,"method":method,"params":params])
                stage = 1
            } else if stage == 1 && message["id"] as? String == start {
                guard message["error"] == nil, let result = message["result"] as? Row else { throw HUDError("Discovering the new Codex thread was refused.") };return result
            }
        }
        throw HUDError("New Codex setup timed out or is uncertain. No prompt was sent; inspect its new transport before retrying.")
    }
}
