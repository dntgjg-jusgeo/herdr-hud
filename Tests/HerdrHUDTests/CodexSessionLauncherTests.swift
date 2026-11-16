import XCTest
import Darwin
import CryptoKit
@testable import HerdrHUD

final class CodexSessionLauncherTests: XCTestCase {
    final class Fixture {
        let root: URL
        let executable: String
        let thread = UUID().uuidString.lowercased()
        var terminals: [String:Row] = [:], requests: [Row] = [], sockets: [Int32] = []
        var core = "test-core", bootstrapCalls = 0, failBootstrap = false, uncertainTUI = false, delayedIdentity = false, ambiguousThreads = false
        var tuiReads = 0, officialAlias = false
        var externalSockets: [String] = []
        lazy var client = HCClient(binary:"/fixture/hc",execute:run)
        init() throws {
            root = URL(fileURLWithPath:"/private/tmp/csl-"+String(UUID().uuidString.prefix(8)),isDirectory:true)
            try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
            executable = root.appendingPathComponent("codex").path
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to:URL(fileURLWithPath:executable))
            _ = chmod(executable,0o700)
        }
        deinit { for fd in sockets { _ = Darwin.close(fd) };for path in externalSockets { _ = unlink(path) };try? FileManager.default.removeItem(at:root) }
        var store: URL { root.appendingPathComponent("sessions",isDirectory:true) }
        func makeSocket(_ path: String) throws {
            let fd = Darwin.socket(AF_UNIX,SOCK_STREAM,0);guard fd >= 0 else { throw HUDError("socket fixture") }
            var address = sockaddr_un();address.sun_family = sa_family_t(AF_UNIX)
            let bytes = Array(path.utf8)+[0]
            guard bytes.count <= MemoryLayout.size(ofValue:address.sun_path) else { close(fd);throw HUDError("fixture path") }
            withUnsafeMutableBytes(of:&address.sun_path) { $0.copyBytes(from:bytes) }
            let result = withUnsafePointer(to:&address) { $0.withMemoryRebound(to:sockaddr.self,capacity:1) { Darwin.bind(fd,$0,socklen_t(MemoryLayout<sockaddr_un>.size)) } }
            guard result == 0 else { close(fd);throw HUDError("fixture bind") };_ = chmod(path,0o600);sockets.append(fd)
        }
        func serverSocket(_ alias: String) throws {
            guard officialAlias else { try makeSocket(alias);return }
            let canonicalParent = URL(fileURLWithPath:alias).deletingLastPathComponent().path
            guard let parent = realpath(canonicalParent,nil), let temporary = realpath("/tmp",nil) else { throw HUDError("fixture canonical path") }
            defer { free(parent);free(temporary) }
            let hash = SHA256.hash(data:Data((String(cString:parent)+"/s").utf8)).map { String(format:"%02x",$0) }.joined()
            let shared = String(cString:temporary)+"/codex-daemon-\(geteuid())"
            var info = stat()
            if lstat(shared,&info) != 0 { guard errno == ENOENT, mkdir(shared,0o700) == 0 else { throw HUDError("fixture private directory") } }
            guard lstat(shared,&info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == geteuid(), info.st_mode & 0o777 == 0o700 else { throw HUDError("fixture private directory") }
            let physical = shared+"/"+hash
            try makeSocket(physical);externalSockets.append(physical)
            try FileManager.default.createSymbolicLink(atPath:alias,withDestinationPath:physical)
        }
        func query(socket: String, method: String, params: Row) throws -> Row {
            bootstrapCalls += 1;if failBootstrap { throw HUDError("fixture failure") }
            XCTAssertEqual(method,"thread/loaded/list");XCTAssertEqual(params["limit"] as? Int,2)
            if terminals["t2"] == nil { return ["data":[String](),"nextCursor":NSNull()] }
            return ["data":ambiguousThreads ? [thread,UUID().uuidString] : [thread],"nextCursor":NSNull()]
        }
        func launcher(store: URL? = nil,onTerminalCreated: @escaping (String) -> Void = { _ in }) -> CodexSessionLauncher {
            CodexSessionLauncher(client:client,codex:executable,directory:store ?? self.store,query:query,wait:{},readinessAttempts:8,onTerminalCreated:onTerminalCreated)
        }
        func run(_ invocation: Invocation) throws -> String {
            let calls = try String(decoding:invocation.input!,as:UTF8.self).split(separator:"\n").map { try JSONSerialization.jsonObject(with:Data($0.utf8)) as! Row }
            return try calls.map { request -> String in
                requests.append(request)
                let params = request["params"] as! Row, method = request["method"] as! String
                let result: Row
                switch method {
                case "hello":result = ["generation":1,"core":["id":core],"framed":false]
                case "terminal.run":
                    let labels = params["labels"] as! [String:String], role = labels["hud.codex.role"]!
                    let address = role == "transport" ? "t1" : "t2", pid = role == "transport" ? 10 : 20
                    let args = params["argv"] as! [String]
                    var terminal: Row = ["address":address,"created_ms":pid*10,"pid":pid,"state":"live","argv":args,
                        "cwd":params["cwd"]!,"labels":labels,"foreground":["pid":pid+100,"argv":args,"cwd":params["cwd"]!],
                        "status":["app":role == "tui" ? "codex" : "","state":"idle"]]
                    if role == "transport" { try serverSocket(String(args.last!.dropFirst("unix://".count))) }
                    if role == "tui" && delayedIdentity {
                        terminal["status"] = ["app":"","state":"idle"]
                        terminal["foreground"] = ["pid":pid+50,"argv":args,"cwd":params["cwd"]!]
                    }
                    terminals[address] = terminal
                    if role == "tui" && uncertainTUI { throw HUDError("uncertain fixture TUI") }
                    result = terminal
                case "terminal.get":
                    let address = params["terminal"] as! String
                    if address == "t2", delayedIdentity {
                        tuiReads += 1
                        if tuiReads >= 3 {
                            terminals[address]!["status"] = ["app":"codex","state":"idle"]
                            var foreground = terminals[address]!["foreground"] as! Row;foreground["pid"] = 120;terminals[address]!["foreground"] = foreground
                        }
                    }
                    result = terminals[address] ?? [:]
                case "terminal.kill":
                    let address = params["terminal"] as! String
                    XCTAssertEqual(address,"t1","only this launch's empty server may be cleaned up")
                    terminals[address]?["state"] = "finished";result = terminals[address] ?? [:]
                default:throw HUDError("unexpected fixture method")
                }
                return encode(["jsonrpc":"2.0","id":request["id"]!,"result":result])+"\n"
            }.joined()
        }
        var mutations: [Row] { requests.filter { ["terminal.run","terminal.kill"].contains($0["method"] as? String ?? "") } }
    }
    func testNewSessionUsesExplicitThreadAndModelWithoutSendingAPrompt() throws {
        let f = try Fixture(), launcher = f.launcher()
        let result = try launcher.launch(directory:f.root.path), descriptor = result["descriptor"] as! Row, row = result["agent"] as! Row
        XCTAssertGreaterThanOrEqual(f.bootstrapCalls,2);XCTAssertEqual(descriptor["threadID"] as? String,f.thread)
        let runs = f.requests.filter { $0["method"] as? String == "terminal.run" }.map { $0["params"] as! Row }
        XCTAssertEqual(runs.count,2)
        let server = runs[0]["argv"] as! [String], tui = runs[1]["argv"] as! [String]
        XCTAssertEqual(Array(server.prefix(3)),[f.executable,"app-server","--listen"])
        XCTAssertEqual(Array(tui.prefix(3)),[f.executable,"--remote",server[3]])
        XCTAssertFalse(tui.contains("resume"));XCTAssertFalse(tui.contains(f.thread))
        XCTAssertTrue(tui.contains("model_reasoning_effort=\"medium\""));XCTAssertTrue(tui.contains("gpt-6-astra"))
        XCTAssertFalse(f.requests.contains { ["terminal.send","terminal.keys"].contains($0["method"] as? String ?? "") })
        XCTAssertEqual((try launcher.binding(for:row))?["threadID"] as? String,f.thread)
        XCTAssertEqual((try f.launcher().binding(for:row))?["threadID"] as? String,f.thread,"binding survives launcher reconstruction")
        let file = f.store.appendingPathComponent(descriptor["folder"] as! String).appendingPathComponent("session.json")
        let permissions = try FileManager.default.attributesOfItem(atPath:file.path)[.posixPermissions] as! NSNumber
        XCTAssertEqual(permissions.intValue & 0o777,0o600)
        XCTAssertFalse(tui.contains("--dangerously-bypass-approvals-and-sandbox"))
        XCTAssertFalse(tui.contains("--ask-for-approval"))
    }
    func testWaitsForReportedCodexAndFinalForegroundIdentityBeforeCommitting() throws {
        let f = try Fixture();f.delayedIdentity = true
        var created: [String] = [], shownAt = 0
        let result = try f.launcher(onTerminalCreated:{ created.append($0);shownAt = f.tuiReads }).launch(directory:f.root.path), row = result["agent"] as! Row, descriptor = result["descriptor"] as! Row
        XCTAssertEqual(created,["t2"]);XCTAssertLessThan(shownAt,3)
        XCTAssertGreaterThanOrEqual(f.tuiReads,4)
        XCTAssertEqual((descriptor["tui"] as? Row)?["foreground_pid"] as? Int,120)
        XCTAssertEqual((row["agent_session"] as? Row)?["app"] as? String,"codex")
        XCTAssertNotNil(try f.launcher().binding(for:row))
    }
    func testBootstrapFailureCleansOnlyOwnNewEmptyServer() throws {
        let f = try Fixture();f.failBootstrap = true
        XCTAssertThrowsError(try f.launcher().launch(directory:f.root.path))
        XCTAssertEqual(f.mutations.map { $0["method"] as! String },["terminal.run","terminal.kill"])
        XCTAssertNil(f.terminals["t2"])
    }
    func testAmbiguousLoadedThreadsNeverCommitOrKillInteractiveTUI() throws {
        let f = try Fixture();f.ambiguousThreads = true
        XCTAssertThrowsError(try f.launcher().launch(directory:f.root.path))
        XCTAssertNotNil(f.terminals["t2"])
        XCTAssertFalse(f.requests.contains { $0["method"] as? String == "terminal.kill" })
        let row = try HCClient.row(f.terminals["t2"]!,core:f.core,machines:[])!
        XCTAssertNil(try f.launcher().binding(for:row))
    }
    func testUncertainTUILaunchNeverKillsAndPendingCannotBecomeBinding() throws {
        let f = try Fixture();f.uncertainTUI = true
        XCTAssertThrowsError(try f.launcher().launch(directory:f.root.path))
        XCTAssertFalse(f.requests.contains { $0["method"] as? String == "terminal.kill" })
        let row = try HCClient.row(f.terminals["t2"]!,core:f.core,machines:[])!
        XCTAssertNil(try f.launcher().binding(for:row))
    }
    func testReplacedServerTUIAndSocketCannotBind() throws {
        for replacement in 0...2 {
            let f = try Fixture(), launcher = f.launcher(), result = try launcher.launch(directory:f.root.path), row = result["agent"] as! Row
            if replacement == 0 { f.terminals["t1"]!["created_ms"] = 999 }
            else if replacement == 1 { var foreground = f.terminals["t2"]!["foreground"] as! Row;foreground["pid"] = 999;f.terminals["t2"]!["foreground"] = foreground }
            else { let socket = (result["descriptor"] as! Row)["socket"] as! String;_ = unlink(socket);try f.makeSocket(socket) }
            XCTAssertThrowsError(try launcher.binding(for:row))
        }
    }
    func testOfficialOwnedAliasResolvesOnlyItsHashedPhysicalSocket() throws {
        let f = try Fixture();f.officialAlias = true
        let launcher = f.launcher(), result = try launcher.launch(directory:f.root.path), descriptor = result["descriptor"] as! Row, row = result["agent"] as! Row
        XCTAssertNotEqual(descriptor["socket"] as? String,descriptor["socketAlias"] as? String)
        XCTAssertTrue((descriptor["socket"] as! String).contains("/codex-daemon-\(geteuid())/"))
        XCTAssertEqual((try launcher.binding(for:row))?["threadID"] as? String,f.thread)
        let alias = descriptor["socketAlias"] as! String
        _ = unlink(alias)
        try FileManager.default.createSymbolicLink(atPath:alias,withDestinationPath:f.executable)
        XCTAssertThrowsError(try launcher.binding(for:row),"arbitrary symlink targets must not be followed")
    }
    func testPrivateStorageRejectsSymlinkAndLongSocketBeforeStartingAnything() throws {
        let f = try Fixture(), alias = f.root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at:alias,withDestinationURL:f.root)
        XCTAssertThrowsError(try f.launcher(store:alias).launch(directory:f.root.path));XCTAssertTrue(f.mutations.isEmpty)
        let long = f.root.appendingPathComponent(String(repeating:"x",count:80))
        XCTAssertThrowsError(try f.launcher(store:long).launch(directory:f.root.path));XCTAssertTrue(f.mutations.isEmpty)
    }
}
