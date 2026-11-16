import XCTest
import AppKit
@testable import HerdrHUD

final class OrcaOpenCodeTests:XCTestCase {
    final class Fixture {
        let endpoint=URL(string:"http://127.0.0.1:43981")!
        let session="sesfixture",model="deepseek/deepseek-v4.1-flash",directory="/private/tmp/fixture"
        var pid:Any=123,version="2.1.4",rootCount=1,otherRoot=false,working=false,blocked=false,wrongAck=false,failMutation=false
        var requests:[URLRequest]=[],dropImages=false,changeImages=false,extraModel=false,extraProvider=false
        var boundaryCursor=false,continuationHasRoot=false
        var root:Row { ["id":session,"model":["providerID":"orcarouter","id":model],"location":["directory":directory],"time":["created":1,"updated":1]] }
        func transport(_ request:URLRequest)throws->(Data,HTTPURLResponse) {
            requests.append(request)
            let path=request.url!.path
            var value:Row=[:]
            if request.httpMethod == "POST",path.hasSuffix("/prompt") {
                if failMutation { throw HUDError("fixture lost connection") }
                let body=try JSONSerialization.jsonObject(with:request.httpBody!) as! Row
                var files=(body["files"] as? [Row] ?? []).map { row -> Row in
                    let uri=row["uri"] as! String
                    return ["data":String(uri.split(separator:",").last!),"mime":"image/png","source":["type":"inline"]]
                }
                if dropImages { files=[] }
                if changeImages,!files.isEmpty { files[0]["data"]="changed" }
                value=["data":["id":wrongAck ? "msg_wrong":body["id"]!,"sessionID":session,"type":"user","delivery":"queue","payload":["text":body["text"]!,"files":files]]]
            } else if request.httpMethod == "POST",path == "/api/session" { value=["data":root]
            } else if path == "/api/info" { value=["version":version,"pid":pid]
            } else if path == "/api/model" {
                var models:[Row]=[["id":model,"modelID":model,"providerID":"orcarouter","enabled":true]]
                if extraModel { models.append(["id":"anthropic/claude-excluded","modelID":"anthropic/claude-excluded","providerID":"orcarouter","enabled":true]) }
                value=["location":["directory":directory],"data":models]
            } else if path == "/api/provider" {
                var providers:[Row]=[["id":"orcarouter","package":"@opencode/ai/providers/openai-compatible","settings":["baseURL":"https://api.orcarouter.ai/v1"]]]
                if extraProvider { providers.append(["id":"openai"] ) }
                value=["location":["directory":directory],"data":providers]
            } else if path == "/api/session" {
                if request.url!.query?.contains("cursor=") == true {
                    value=["data":continuationHasRoot ? [["id":"sesother"]]:[],"cursor":["next":NSNull(),"previous":NSNull()]]
                } else {
                    value=["data":rootCount == 0 ? [] : otherRoot ? [root,["id":"sesother"]] : [root],"cursor":["next":boundaryCursor ? "opaque-boundary-token" as Any:NSNull()]]
                }
            } else if path == "/api/session/active" { value=["data":working ? [session:["type":"running"]]:[:]]
            } else if path.hasSuffix("/permission") { value=["data":blocked ? [["sessionID":session,"id":"perm_test"]]:[]]
            } else if path.hasSuffix("/form") { value=["data":[]]
            } else { XCTFail("Unexpected path \(path)") }
            return (try JSONSerialization.data(withJSONObject:value),HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:nil)!)
        }
        func adapter()throws->OrcaOpenCode {
            try OrcaOpenCode(endpoint:endpoint,password:String(repeating:"x",count:64),serverPID:123,sessionID:session,modelID:model,directory:directory,transport:transport)
        }
    }
    func testExactEmptySessionBootstrapSendsNoPrompt()throws {
        let f=Fixture()
        XCTAssertEqual(try OrcaOpenCode.create(endpoint:f.endpoint,password:String(repeating:"x",count:64),sessionID:f.session,modelID:f.model,directory:f.directory,transport:f.transport),123)
        XCTAssertEqual(f.requests.map{ $0.url!.path },["/api/info","/api/model","/api/provider","/api/session"])
        let body=try JSONSerialization.jsonObject(with:f.requests[3].httpBody!) as! Row
        XCTAssertEqual((body["model"] as? Row)?["id"] as? String,f.model)
        XCTAssertNil(body["text"])
    }
    func testStatusIsNativeBoundAndPendingInputBlocks()throws {
        let f=Fixture(),a=try f.adapter()
        XCTAssertEqual(try a.snapshot()["agent_status"] as? String,"idle")
        f.working=true;XCTAssertEqual(try a.snapshot()["agent_status"] as? String,"working")
        f.blocked=true;let state=try a.snapshot()
        XCTAssertEqual(state["agent_status"] as? String,"blocked");XCTAssertEqual(state["canQueue"] as? Bool,false)
        XCTAssertThrowsError(try a.prompt(text:"must refuse"))
        XCTAssertFalse(f.requests.contains{ $0.httpMethod == "POST" })
    }
    func testNativeDurablePromptCarriesExactIDAndQueueWhileWorking()throws {
        let f=Fixture();f.working=true;let a=try f.adapter()
        let reply=try a.prompt(text:"A follow up")
        XCTAssertEqual(reply["accepted"] as? Bool,true)
        let sent=f.requests.filter{ $0.httpMethod == "POST" };XCTAssertEqual(sent.count,1)
        let body=try JSONSerialization.jsonObject(with:sent[0].httpBody!) as! Row
        XCTAssertEqual(body["delivery"] as? String,"queue");XCTAssertEqual(body["id"] as? String,reply["messageID"] as? String)
        XCTAssertEqual(sent[0].url!.path,"/api/session/sesfixture/prompt")
    }
    func testValidatedImagesUseInlineDataAndDurableAck()throws {
        let f=Fixture(),a=try f.adapter()
        let png=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:4,pixelsHigh:4,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!.representation(using:.png,properties:[:])!
        let images=try ImageAttachment.parse([["data":png.base64EncodedString()]])
        XCTAssertEqual(try a.prompt(text:"",attachments:images)["ok"] as? Bool,true)
        let sent=f.requests.last!,body=try JSONSerialization.jsonObject(with:sent.httpBody!) as! Row
        let files=body["files"] as! [Row]
        XCTAssertTrue((files[0]["uri"] as! String).hasPrefix("data:image/png;base64,"))
        XCTAssertFalse((files[0]["uri"] as! String).contains("file:"))
    }
    func testPostDispatchFailureLatchesWithoutAutomaticRetry()throws {
        for malformed in [false,true] {
            let f=Fixture();f.failMutation = !malformed;f.wrongAck=malformed;let a=try f.adapter()
            XCTAssertThrowsError(try a.prompt(text:"one")) { error in XCTAssertEqual((error as? OrcaOpenCode.Failure)?.uncertain,true) }
            XCTAssertTrue(a.uncertain)
            XCTAssertThrowsError(try a.prompt(text:"two"))
            XCTAssertEqual(f.requests.filter{ $0.httpMethod == "POST" }.count,1)
            XCTAssertEqual(try a.reconcile()["uncertain"] as? Bool,false)
        }
    }
    func testDroppedOrChangedImageAcknowledgementRemainsUncertain()throws {
        let png=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:4,pixelsHigh:4,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!.representation(using:.png,properties:[:])!
        let images=try ImageAttachment.parse([["data":png.base64EncodedString()]])
        for dropped in [true,false] {
            let f=Fixture();f.dropImages=dropped;f.changeImages = !dropped;let a=try f.adapter()
            XCTAssertThrowsError(try a.prompt(text:"Image",attachments:images)) { XCTAssertEqual(($0 as? OrcaOpenCode.Failure)?.uncertain,true) }
            XCTAssertTrue(a.uncertain)
        }
    }
    func testChangedServerOrChatFailsBeforeMutation()throws {
        let f=Fixture(),a=try f.adapter()
        f.pid=true;XCTAssertThrowsError(try a.prompt(text:"bad pid"))
        f.pid=123;f.otherRoot=true;XCTAssertThrowsError(try a.prompt(text:"new chat"))
        f.otherRoot=false;f.rootCount=0;XCTAssertThrowsError(try a.prompt(text:"missing chat"))
        XCTAssertFalse(f.requests.contains{ $0.httpMethod == "POST" })
    }
    func testBroadCatalogRefusesBeforeSessionCreationOrPrompt()throws {
        let f=Fixture();f.extraModel=true
        XCTAssertThrowsError(try OrcaOpenCode.create(endpoint:f.endpoint,password:String(repeating:"x",count:64),sessionID:f.session,modelID:f.model,directory:f.directory,transport:f.transport))
        XCTAssertThrowsError(try f.adapter().prompt(text:"must not route"))
        f.extraModel=false;f.extraProvider=true
        XCTAssertThrowsError(try f.adapter().prompt(text:"must not use another provider"))
        XCTAssertFalse(f.requests.contains{ $0.httpMethod == "POST" })
    }
    func testNonemptyFinalPageBoundaryCursorRequiresEmptyContinuation()throws {
        let f=Fixture();f.boundaryCursor=true;let adapter=try f.adapter()
        XCTAssertEqual(try adapter.snapshot()["agent_status"] as? String,"idle")
        let continuation=f.requests.first{ $0.url?.query?.contains("cursor=") == true }
        XCTAssertNotNil(continuation)
        XCTAssertTrue(continuation!.url!.query!.contains("parentID=null"))
        f.continuationHasRoot=true
        XCTAssertThrowsError(try adapter.prompt(text:"must not reach another chat"))
        XCTAssertFalse(f.requests.contains{ $0.httpMethod == "POST" })
    }
    func testEndpointAndDerivedPasswordBoundaries()throws {
        for text in ["http://localhost:1234","https://127.0.0.1:1234","http://127.0.0.1:1234/path","http://name:pass@127.0.0.1:1234","http://127.0.0.1:1234?secret=x"] { XCTAssertFalse(OrcaOpenCode.validEndpoint(URL(string:text)!)) }
        XCTAssertEqual(OrcaOpenCode.password(token:"fixture",nonce:"one").count,64)
        XCTAssertNotEqual(OrcaOpenCode.password(token:"fixture",nonce:"one"),OrcaOpenCode.password(token:"fixture",nonce:"two"))
        XCTAssertNotEqual(OrcaOpenCode.password(token:"fixture",nonce:"one"),OrcaOpenCode.password(token:"other",nonce:"one"))
    }
    func testOpenCodeDiscoveryDoesNotTrustOSCOrHeadlessServer()throws {
        XCTAssertEqual(HCClient.provider(["foreground":["argv":["/Users/example/.opencode/bin/opencode","--server","http://127.0.0.1:1234"]]]),"opencode")
        XCTAssertNil(HCClient.provider(["foreground":["argv":["/Users/example/.opencode/bin/opencode","serve"]]]))
        let row=try HCClient.row(["state":"live","address":"1","created_ms":1,"foreground":["argv":["opencode"],"pid":123],"status":["app":"opencode","state":"idle"]],core:"core",machines:[])!
        XCTAssertEqual(row["agent_status"] as? String,"unknown");XCTAssertEqual(row["can_prompt"] as? Bool,false)
    }
}
