import XCTest
@testable import HerdrHUD

final class HCTests: XCTestCase {
    func terminal(_ state: String = "idle", address: String = "t3", created: Int = 100, pid: Int = 123, provider: String = "claude") -> Row {
        ["address":address,"created_ms":created,"state":"live","cwd":"/fixture/project","name":"fixture","labels":["workspace":"Fixture"],
         "foreground":["pid":pid,"name":provider,"argv":["/fixture/"+provider],"cwd":"/fixture/project"],"status":["app":provider,"state":state]]
    }
    final class Fixture {
        var core = "fixture-core", terminals: [Row] = [], machines: [Row] = [], calls: [Invocation] = [], offline = false
        var sendResult: Row = ["turn":2,"started":NSNull(),"status":NSNull()]
        var sendError = false, malformed = false
        var screenText = "Fixture reply", screenHow = "screen", screenComplete = true
        var features: [String] = []
        var checkedResult: Row = ["outcome":"written"]
        var snapshotCore: String?
        var afterRead: (() -> Void)?
        var afterPut: (() -> Void)?
        var putResult: Row?
        lazy var client = HerdrClient(binary:"/fixture/hc",execute:run)
        func run(_ invocation: Invocation) throws -> String {
            calls.append(invocation)
            if offline { throw HUDError("offline") }
            let requests = try String(decoding:invocation.input!,as:UTF8.self).split(separator:"\n").map { try JSONSerialization.jsonObject(with:Data($0.utf8)) as! Row }
            return try requests.map { request -> String in
                let method = request["method"] as! String, params = request["params"] as! Row
                var result: Row
                switch method {
                case "hello":result = ["core":["id":core],"generation":1,"framed":false,"features":features]
                case "terminal.input_snapshot":result = ["token":"guarded-token","text":screenText,"complete":screenComplete,"terminal":terminals[0],"core_id":snapshotCore ?? core]
                case "terminal.keys_checked":
                    if sendError { throw HUDError("unknown outcome") }; result = checkedResult
                case "machine.list":result = ["machines":machines]
                case "terminal.list":result = ["terminals":terminals]
                case "terminal.get":result = terminals.first { $0["address"] as? String == params["terminal"] as? String } ?? [:]
                case "terminal.read":result = ["text":screenText, "complete":screenComplete, "how":screenHow];afterRead?()
                case "terminal.keys":
                    if sendError { throw HUDError("unknown outcome") }
                    result = sendResult
                case "terminal.put":
                    let bytes=Data(base64Encoded:params["data"] as! String)!
                    result=putResult ?? ["path":"/fixture/image.png","bytes":bytes.count];afterPut?()
                case "terminal.send":
                    XCTAssertEqual(params["if"] as? String,"idle");XCTAssertEqual(params["force"] as? Bool,false)
                    XCTAssertEqual(params["wait"] as? Bool,false)
                    if sendError { throw HUDError("unknown outcome") }
                    if malformed { return "not-json\n" }
                    result = sendResult
                default:throw HUDError("Unexpected method")
                }
                return encode(["jsonrpc":"2.0","id":request["id"]!,"result":result])+"\n"
            }.joined()
        }
        var mutations: [Invocation] { calls.filter(\.mutation) }
        func id() -> String { (client.snapshot()["agents"] as! [Row])[0]["id"] as! String }
    }
    func testDiscoveryReadAndLiteralSend() throws {
        let f=Fixture();f.terminals=[terminal(),terminal(address:"t7",provider:"codex")]
        let snapshot=f.client.snapshot(),rows=snapshot["agents"] as! [Row]
        XCTAssertEqual(rows.count,2);XCTAssertEqual(rows[0]["workspace_label"] as? String,"Fixture")
        let id=rows[0]["id"] as! String
        XCTAssertEqual(try f.client.output(id)["text"] as? String,"Fixture reply")
        let text="private 'literal' $(nothing) 🐑\nnext"
        XCTAssertEqual(try f.client.prompt(id,text)["ok"] as? Bool,true)
        XCTAssertEqual(f.mutations.count,1)
        XCTAssertFalse(f.mutations[0].arguments.joined().contains(text))
        let request=try JSONSerialization.jsonObject(with:f.mutations[0].input!) as! Row
        XCTAssertEqual((request["params"] as! Row)["text"] as? String,text)
        XCTAssertEqual(f.mutations[0].arguments,["connect","--session","default"])
    }
    func testBusyBlockedUnknownDoneNeverSend() throws {
        for state in ["working","blocked","unknown","done","error"] {
            let f=Fixture();f.terminals=[terminal(state)];let id=f.id()
            XCTAssertThrowsError(try f.client.prompt(id,"fixture"));XCTAssertTrue(f.mutations.isEmpty)
        }
    }
    func testReplacementAndChangedCoreFailClosed() throws {
        for replacement in [terminal(created:101),terminal(pid:456),terminal(provider:"codex")] {
            let f=Fixture();f.terminals=[terminal()];let id=f.id();f.terminals=[replacement]
            XCTAssertThrowsError(try f.client.output(id));XCTAssertThrowsError(try f.client.prompt(id,"fixture"));XCTAssertTrue(f.mutations.isEmpty)
        }
        let f=Fixture();f.terminals=[terminal()];let id=f.id();f.core="replacement-core"
        XCTAssertThrowsError(try f.client.prompt(id,"fixture"));XCTAssertTrue(f.mutations.isEmpty)
    }
    func testChangedStatusBetweenSnapshotAndSendRefused() throws {
        let f=Fixture();f.terminals=[terminal()];let id=f.id();f.terminals=[terminal("working")]
        XCTAssertThrowsError(try f.client.prompt(id,"fixture"));XCTAssertTrue(f.mutations.isEmpty)
    }
    func testMalformedOrUnknownAcknowledgementNeverRetries() throws {
        for mode in 0...3 {
            let f=Fixture();f.terminals=[terminal()];let id=f.id()
            if mode==0 {f.sendError=true};if mode==1 {f.malformed=true};if mode==2 {f.sendResult=["turn":true]};if mode==3 {f.sendResult=["started":true]}
            XCTAssertThrowsError(try f.client.prompt(id,"fixture")) { XCTAssertTrue($0.localizedDescription.contains("uncertain")) }
            XCTAssertEqual(f.mutations.count,1)
        }
    }
    func testOfflineCacheAndReconnect() throws {
        let f=Fixture();f.terminals=[terminal()];let id=f.id();f.offline=true
        let offline=f.client.snapshot()["agents"] as! [Row]
        XCTAssertEqual(offline.count,1);XCTAssertEqual(offline[0]["online"] as? Bool,false)
        XCTAssertThrowsError(try f.client.prompt(id,"fixture"));XCTAssertTrue(f.mutations.isEmpty)
        f.offline=false;XCTAssertEqual((f.client.snapshot()["agents"] as! [Row])[0]["online"] as? Bool,true)
    }
    func testRemoteRoutingUsesCoreAndValidatesMachineConfiguration() throws {
        let f=Fixture();f.machines=[["id":"remote-core","name":"worker","state":"connected","target":"private-target","via":true,"session":"named"]]
        f.terminals=[terminal(address:"worker/t7")];let id=f.id()
        _=try f.client.output(id);_=try f.client.prompt(id,"fixture")
        XCTAssertTrue(f.calls.allSatisfy { $0.executable=="/fixture/hc" && !$0.arguments.joined().contains("private-target") })
        let request=try JSONSerialization.jsonObject(with:f.mutations[0].input!) as! Row
        XCTAssertEqual((request["params"] as! Row)["terminal"] as? String,"worker/t7")
        f.machines[0]["target"]="changed"
        XCTAssertThrowsError(try f.client.prompt(id,"fixture"));XCTAssertEqual(f.mutations.count,1)
        f.machines[0]["state"]="unreachable"
        let offline=f.client.snapshot()["agents"] as! [Row];XCTAssertEqual(offline[0]["online"] as? Bool,false)
        XCTAssertThrowsError(try f.client.output(id))
        f.machines=[];XCTAssertTrue((f.client.snapshot()["agents"] as! [Row]).isEmpty)
    }
    func testUnknownForegroundExcludedAndMissingIdentityRefused() throws {
        let f=Fixture();f.terminals=[terminal(provider:"bash")];XCTAssertTrue((f.client.snapshot()["agents"] as! [Row]).isEmpty)
        var t=terminal();t.removeValue(forKey:"created_ms");f.terminals=[t]
        XCTAssertFalse((f.client.snapshot()["discoveryError"] as! String).isEmpty)
    }
    func testDuplicateTerminalIdentityFailsClosed() {
        let f=Fixture();f.terminals=[terminal(),terminal()]
        let snapshot=f.client.snapshot()
        XCTAssertTrue((snapshot["agents"] as! [Row]).isEmpty)
        XCTAssertTrue((snapshot["discoveryError"] as! String).contains("duplicate"))
    }
    func testProviderArgumentAndMismatchedStatusCannotEnablePrompt() throws {
        let f=Fixture();var t=terminal()
        t["foreground"]=["pid":123,"name":"python3","argv":["/usr/bin/python3","/fixture/inspect.py","codex"],"cwd":"/fixture"]
        f.terminals=[t];XCTAssertTrue((f.client.snapshot()["agents"] as! [Row]).isEmpty)
        t=terminal();t["status"]=["app":"other-program","state":"idle"];f.terminals=[t]
        let id=f.id();XCTAssertThrowsError(try f.client.prompt(id,"fixture"));XCTAssertTrue(f.mutations.isEmpty)
        t=terminal();t["foreground"]=["pid":123,"name":"node","argv":["/usr/bin/node","/fixture/claude.js","task"],"cwd":"/fixture"]
        f.terminals=[t];XCTAssertEqual((f.client.snapshot()["agents"] as! [Row]).count,1)
    }
    func testProcessRunnerReturnsOnMatchingRPCReplyWithoutBridgeEOF() throws {
        let reply=encode(["jsonrpc":"2.0","id":"fixture-id","result":["turn":1]])
        let script="import sys,time\nsys.stdin.readline()\nprint("+String(reflecting:reply)+",flush=True)\ntime.sleep(10)"
        let start=Date()
        let output=try ProcessRunner(timeout:5).run(Invocation(executable:"/usr/bin/python3",arguments:["-c",script],mutation:false,input:Data("{}\n".utf8),responseIDs:["fixture-id"]))
        XCTAssertTrue(output.contains("fixture-id"));XCTAssertLessThan(Date().timeIntervalSince(start),3)
    }
    func testCodexServiceProcessesAreNotUserAgents() {
        for argv in [["/fixture/codex","app-server","--listen","unix:///fixture/socket"],["/fixture/node","/fixture/codex.js","app-server","proxy"],["/fixture/codex","remote-control"]] {
            XCTAssertNil(HCClient.provider(["foreground":["argv":argv]]))
        }
        XCTAssertEqual(HCClient.provider(["foreground":["argv":["/fixture/codex","--remote","unix:///fixture/socket"]]]),"codex")
    }

}
