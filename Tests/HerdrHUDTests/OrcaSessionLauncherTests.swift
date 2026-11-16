import XCTest
@testable import HerdrHUD

final class OrcaSessionLauncherTests: XCTestCase {
    func testConfigurationPreservesVerifiedVisionCapability() throws {
        var model:Row=["id":"fixture/vision","name":"Fixture","openAIChat":true,"vision":true]
        let provider="herdr-orca-"+String(repeating:"a",count:32)
        func inputs(_ model:Row)throws->[String]? {
            let config=try OrcaSessionLauncher.configuration(model:model,providerID:provider)
            let providers=config["providers"] as! [String:Row],models=providers[provider]!["models"] as! [String:Row]
            return (models["fixture/vision"]!["capabilities"] as? Row)?["input"] as? [String]
        }
        XCTAssertEqual(try inputs(model),["text","image"])
        model.removeValue(forKey:"vision");XCTAssertEqual(try inputs(model),["text"])
    }
    final class Fixture {
        let root:URL, executable:String
        let key="fixture-key-never-a-real-secret"
        var terminals:[String:Row]=[:],requests:[Row]=[],events:[String]=[]
        var spec:Row=[:],createCalls=0,uncertainTUI=false,listener=true,callback:[String]=[]
        lazy var client=HCClient(binary:"/fixture/hc",execute:run)
        init() throws {
            root=URL(fileURLWithPath:"/private/tmp/orca-launch-"+String(UUID().uuidString.prefix(8)),isDirectory:true)
            try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
            executable=root.appendingPathComponent("opencode").path
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to:URL(fileURLWithPath:executable));try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:executable)
        }
        deinit { try? FileManager.default.removeItem(at:root) }
        var model:Row { ["id":"deepseek/deepseek-v4.1-flash","name":"DeepSeek fixture","openAIChat":true,"tools":true,"contextLength":1048576,"outputLength":384000,"releaseDate":"2026-09-10","releaseSource":"https://api-docs.deepseek.com/updates/"] }
        func launcher() -> OrcaSessionLauncher {
            OrcaSessionLauncher(client:client,opencode:executable,directory:root.appendingPathComponent("sessions"),credential:{self.key},approve:{$0},
                create:{ endpoint,password,session,model,cwd,provider,pid in
                    self.events.append("create");self.createCalls += 1
                    XCTAssertEqual(self.events.first,"listener");XCTAssertEqual(pid,10);XCTAssertEqual(endpoint.port,43982)
                    XCTAssertEqual(password,OrcaOpenCode.password(token:self.key,nonce:self.spec["nonce"] as! String))
                    XCTAssertTrue(session.hasPrefix("ses"));XCTAssertEqual(model,self.model["id"] as? String);XCTAssertEqual(cwd,self.spec["directory"] as? String)
                    XCTAssertEqual(provider,"herdr-orca-"+(self.spec["nonce"] as! String).replacingOccurrences(of:"-",with:""));return pid
                },port:{43982},listener:{pid,port in self.events.append("listener");XCTAssertEqual(pid,10);XCTAssertEqual(port,43982);return self.listener},wait:{},attempts:3,onTerminalCreated:{self.callback.append($0)})
        }
        func run(_ invocation:Invocation) throws -> String {
            let calls=try String(decoding:invocation.input!,as:UTF8.self).split(separator:"\n").map { try JSONSerialization.jsonObject(with:Data($0.utf8)) as! Row }
            return try calls.map { call -> String in
                requests.append(call);let method=call["method"] as! String,p=call["params"] as! Row;let result:Row
                switch method {
                case "hello":result=["generation":1,"framed":false,"core":["id":"fixture-core"]]
                case "terminal.run":
                    XCTAssertNil(p["env"],"HC must never receive credential environment values")
                    let args=p["argv"] as! [String];XCTAssertEqual(args[0],"/usr/bin/python3")
                    let folder=URL(fileURLWithPath:args[1]).deletingLastPathComponent()
                    spec=try JSONSerialization.jsonObject(with:Data(contentsOf:folder.appendingPathComponent("launch.json"))) as! Row
                    let script=try String(contentsOf:folder.appendingPathComponent("launch.py"),encoding:.utf8)
                    XCTAssertFalse(script.contains(key));XCTAssertFalse(encode(spec).contains(key));XCTAssertFalse(encode(p).contains(key))
                    XCTAssertTrue(script.contains("os.execve"));XCTAssertTrue(script.contains("stderr=subprocess.DEVNULL"))
                    let role=args[2],pid=role == "serve" ? 10:20,address=role == "serve" ? "t1":"t2",endpoint="http://127.0.0.1:43982"
                    let foreground=role == "serve" ? [executable,"serve","--hostname","127.0.0.1","--port","43982"] : [executable,"--server",endpoint,"--session",spec["sessionID"] as! String,p["cwd"] as! String]
                    result=["address":address,"created_ms":pid*10,"pid":pid,"state":"live","argv":args,"cwd":p["cwd"]!,"labels":p["labels"]!,"foreground":["pid":pid,"argv":foreground,"cwd":p["cwd"]!],"status":NSNull()]
                    terminals[address]=result
                    if role == "tui" && uncertainTUI { throw HUDError("uncertain fixture") }
                case "terminal.get":result=terminals[p["terminal"] as! String] ?? [:]
                case "terminal.kill":XCTAssertEqual(p["terminal"] as? String,"t1");result=[:]
                default:throw HUDError("unexpected fixture method")
                }
                return encode(["jsonrpc":"2.0","id":call["id"]!,"result":result])+"\n"
            }.joined()
        }
    }
    func testManagedLaunchKeepsSecretsOutOfHCAndDiskAndPinsUniqueProvider() throws {
        let f=try Fixture(),launcher=f.launcher(),result=try launcher.launch(directory:f.root.path,model:f.model)
        XCTAssertEqual(f.createCalls,1);XCTAssertEqual(f.callback,["t2"])
        let descriptor=result["descriptor"] as! Row,row=result["agent"] as! Row
        XCTAssertEqual(descriptor["serverPID"] as? Int,10);XCTAssertEqual(result["terminalID"] as? String,"t2")
        XCTAssertEqual((try launcher.binding(for:row))?["sessionID"] as? String,descriptor["sessionID"] as? String)
        XCTAssertFalse(encode(descriptor).contains(f.key));XCTAssertNil(descriptor["password"])
        let config=f.spec["config"] as! Row,provider=descriptor["providerID"] as! String,providers=config["providers"] as! [String:Row]
        XCTAssertEqual(Array(providers.keys),[provider]);XCTAssertTrue(provider.hasPrefix("herdr-orca-"));XCTAssertNil(providers["orcarouter"])
        XCTAssertEqual((providers[provider]!["models"] as! Row).count,1)
        XCTAssertNil(config["permissions"],"existing user permissions must not be replaced with allow rules")
        XCTAssertEqual((config["media"] as? Row)?["image"] as? [String:Bool],["auto_resize":false])
        XCTAssertEqual(config["model"] as? String,provider+"/"+(f.model["id"] as! String))
        XCTAssertFalse(f.requests.contains { ["terminal.send","terminal.keys"].contains($0["method"] as? String ?? "") })
        let hmac=OrcaOpenCode.password(token:f.key,nonce:descriptor["nonce"] as! String)
        let firstRun=f.requests.first { $0["method"] as? String == "terminal.run" }!,params=firstRun["params"] as! Row,args=params["argv"] as! [String]
        let launchFolder=URL(fileURLWithPath:args[1]).deletingLastPathComponent()
        for url in try FileManager.default.contentsOfDirectory(at:launchFolder,includingPropertiesForKeys:nil) {
            let value=try Data(contentsOf:url);XCTAssertFalse(String(decoding:value,as:UTF8.self).contains(f.key));XCTAssertFalse(String(decoding:value,as:UTF8.self).contains(hmac))
        }
    }
    func testUnownedListenerPreventsAnyAuthenticatedCreateAndOnlyCleansOwnEmptyServer() throws {
        let f=try Fixture();f.listener=false
        XCTAssertThrowsError(try f.launcher().launch(directory:f.root.path,model:f.model));XCTAssertEqual(f.createCalls,0)
        XCTAssertNil(f.terminals["t2"]);XCTAssertEqual(f.requests.filter { $0["method"] as? String == "terminal.kill" }.count,1)
    }
    func testUncertainTUILaunchNeverKillsInteractiveTerminalAndPendingCannotBind() throws {
        let f=try Fixture();f.uncertainTUI=true
        XCTAssertThrowsError(try f.launcher().launch(directory:f.root.path,model:f.model));XCTAssertEqual(f.createCalls,1)
        XCTAssertFalse(f.requests.contains { $0["method"] as? String == "terminal.kill" })
        let row=try HCClient.row(f.terminals["t2"]!,core:"fixture-core",machines:[])!
        XCTAssertNil(try f.launcher().binding(for:row))
    }
    func testReplacedServerOrChangedEndpointCannotReuseBinding() throws {
        let f=try Fixture(),launcher=f.launcher(),result=try launcher.launch(directory:f.root.path,model:f.model),row=result["agent"] as! Row
        var foreground=f.terminals["t1"]!["foreground"] as! Row;foreground["pid"]=999;f.terminals["t1"]!["foreground"]=foreground
        XCTAssertThrowsError(try launcher.binding(for:row))
    }
    func testListenerProofRejectsMixedWildcardIPv6OrOtherPID() {
        XCTAssertTrue(OrcaSessionLauncher.listenerOutput("p10\nf20\nn127.0.0.1:43982\n",pid:10,port:43982))
        for raw in ["p10\nn127.0.0.1:43982\nn*:43982\n","p10\nn127.0.0.1:43982\nn[::]:43982\n","p11\nn127.0.0.1:43982\n","p10\nn127.0.0.1:43983\n"] {
            XCTAssertFalse(OrcaSessionLauncher.listenerOutput(raw,pid:10,port:43982))
        }
    }

}
