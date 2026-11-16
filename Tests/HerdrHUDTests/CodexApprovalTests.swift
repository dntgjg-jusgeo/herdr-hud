import Foundation
import XCTest
@testable import HerdrHUD

final class CodexApprovalTests:XCTestCase {
    func approval(_ id:Any=17,thread:String="thread-A",modes:Any=["session","always"]) -> Row {
        ["id":id,"method":"mcpServer/elicitation/request","params":["threadId":thread,"turnId":"turn-A","serverName":"Computer Use","mode":"form","message":"Allow this exact app?","requestedSchema":["type":"object","properties":Row()],"_meta":["codex_approval_kind":"mcp_tool_call","tool_name":"ComputerUse","persist":modes]]]
    }
    func ready()throws->CodexApprovals.ProtocolState{
        var p=CodexApprovals.ProtocolState(threadID:"thread-A",epoch:"fixture")
        let first=p.begin();XCTAssertEqual(first["method"] as? String,"initialize")
        let loaded=try p.receive(["id":"hud-fixture-initialize","result":Row()]);XCTAssertEqual(loaded[1]["method"] as? String,"thread/loaded/list")
        let resume=try p.receive(["id":"hud-fixture-loaded","result":["data":["thread-A"]]])
        XCTAssertEqual(Set((resume[0]["params"] as! Row).keys),["threadId","excludeTurns"])
        _=try p.receive(["id":"hud-fixture-resume","result":["thread":["id":"thread-A"]]])
        XCTAssertTrue(p.connected);return p
    }
    func testExactSemanticResponsesAndOfferedScopes()throws{
        for id in [17 as Any,"17" as Any] {
            for choice in ["once","session","always","cancel"] {
                var p=try ready();_=try p.receive(approval(id))
                let card=(p.snapshot["cards"] as! [Row])[0],token=card["token"] as! String
                let response=try p.respond(token:token,choice:choice),result=response["result"] as! Row
                XCTAssertEqual(CodexApprovals.WireID(response["id"]),CodexApprovals.WireID(id))
                XCTAssertEqual(result["action"] as? String,choice == "cancel" ? "cancel":"accept")
                XCTAssertTrue(result["content"] is NSNull)
                if ["session","always"].contains(choice){XCTAssertEqual((result["_meta"] as? Row)?["persist"] as? String,choice)}
                XCTAssertThrowsError(try p.respond(token:token,choice:choice))
                XCTAssertEqual((p.snapshot["cards"] as! [Row])[0]["pending"] as? Bool,true)
                _=try p.receive(["method":"serverRequest/resolved","params":["threadId":"thread-A","requestId":id]])
                XCTAssertTrue((p.snapshot["cards"] as! [Row]).isEmpty)
                _=try p.receive(approval(id));XCTAssertTrue(p.cards.isEmpty)
                XCTAssertThrowsError(try p.respond(token:token,choice:choice))
            }
        }
        var p=try ready();_=try p.receive(approval(modes:[]));let card=(p.snapshot["cards"] as! [Row])[0]
        XCTAssertThrowsError(try p.respond(token:card["token"] as! String,choice:"always"))
        XCTAssertEqual((card["choices"] as! [Row]).count,2)
    }
    func testReplayBufferedUntilReadyAndStrictIdentityChecks()throws{
        var p=CodexApprovals.ProtocolState(threadID:"thread-A",epoch:"fixture")
        _=try p.receive(approval());XCTAssertTrue((p.snapshot["cards"] as! [Row]).isEmpty)
        XCTAssertThrowsError(try p.respond(token:p.cards.values.first!.token,choice:"once"))
        _=try p.receive(["id":"hud-fixture-initialize","result":Row()])
        XCTAssertThrowsError(try p.receive(["id":"hud-fixture-loaded","result":["data":["thread-B"]]]))
        p=try ready();_=try p.receive(approval());let first=p.cards.values.first!.token
        _=try p.receive(approval());XCTAssertEqual(p.cards.values.first!.token,first)
        _=try p.receive(approval("17",thread:"other"));XCTAssertEqual(p.cards.count,1)
        _=try p.receive(["method":"serverRequest/resolved","params":["threadId":"other","requestId":17]])
        XCTAssertEqual(p.cards.count,1)
        var changed=approval(),params=changed["params"] as! Row;params["message"]="Changed permission";changed["params"]=params
        XCTAssertThrowsError(try p.receive(changed))
        XCTAssertThrowsError(try p.receive(["method":"thread/started","params":["thread":["id":"new-chat"]]]))
        var replacement=try ready();_=try replacement.receive(approval());XCTAssertNotEqual(replacement.cards.values.first!.token,first)
        XCTAssertThrowsError(try replacement.respond(token:first,choice:"once"))
    }
    func testTurnCompletionRetiresApprovalAndLateReplay()throws{
        var p=try ready();_=try p.receive(approval());let token=p.cards.values.first!.token
        _=try p.receive(["method":"turn/completed","params":["threadId":"thread-A","turn":["id":"turn-A"]]])
        XCTAssertTrue(p.cards.isEmpty);XCTAssertThrowsError(try p.respond(token:token,choice:"once"))
        _=try p.receive(approval());XCTAssertTrue(p.cards.isEmpty)
        XCTAssertThrowsError(try p.receive(["method":"thread/closed","params":["threadId":"thread-A"]]))
    }
    func testUnsupportedFormsAndBooleanIDsNeverBecomeCards()throws{
        for change in 0...8 {
            var p=try ready(),row=approval(),params=row["params"] as! Row
            switch change {
            case 0:params["mode"]="url"
            case 1:params["requestedSchema"]=["type":"object","properties":["answer":["type":"string"]]]
            case 2:params["_meta"]=["codex_approval_kind":"humanCommand"]
            case 3:params["requestedSchema"]=["type":"object","properties":"invalid"]
            case 4:params["_meta"]=["codex_approval_kind":"mcp_tool_call","userVerification":true]
            case 5:row["id"]=true
            case 6:row["id"]=1.5
            case 7:params["_meta"]=["codex_approval_kind":"mcp_tool_call","codex_requires_user_input":"false"]
            default:params["message"]=String(repeating:"x",count:32_769)
            }
            row["params"]=params;_=try p.receive(row);XCTAssertTrue(p.cards.isEmpty)
        }
    }
    func testEmptyNewThreadWaitsTwoCyclesThenJoinsOnlyExactLoadedThread()throws{
        var p=CodexApprovals.ProtocolState(threadID:"thread-A",epoch:"fixture")
        _=try p.receive(["id":"hud-fixture-initialize","result":Row()])
        _=try p.receive(["id":"hud-fixture-loaded","result":["data":["thread-A"]]])
        for cycle in 0...1 {
            let suffix=cycle == 0 ? "":"-"+String(cycle)
            _=try p.receive(["id":"hud-fixture-resume"+suffix,"error":["code":-32600,"message":"no rollout found for thread id thread-A"]])
            XCTAssertEqual(p.phase,"waiting");XCTAssertFalse(p.connected)
            XCTAssertEqual(p.snapshot["status"] as? String,"Waiting for the first prompt in this new Codex chat.")
            XCTAssertTrue((p.snapshot["cards"] as! [Row]).isEmpty)
            let retry=try XCTUnwrap(p.retryWaiting())
            XCTAssertEqual(retry["id"] as? String,"hud-fixture-loaded-"+String(cycle+1))
            _=try p.receive(["id":"hud-fixture-loaded-"+String(cycle+1),"result":["data":["thread-A"],"nextCursor":NSNull()]])
        }
        _=try p.receive(["id":"hud-fixture-resume-2","result":["thread":["id":"thread-A"]]])
        XCTAssertTrue(p.connected)
        var notReady=CodexApprovals.ProtocolState(threadID:"thread-A",epoch:"fixture")
        _=try notReady.receive(["id":"hud-fixture-initialize","result":Row()])
        _=try notReady.receive(["id":"hud-fixture-loaded","result":["data":["thread-A"]]])
        XCTAssertThrowsError(try notReady.receive(["id":"hud-fixture-resume","error":["code":-32601,"message":"list_turns is not supported yet"]])) { error in
            XCTAssertTrue(error.localizedDescription.contains("history is not ready"))
        }
        for rows in [[String](),["thread-A","thread-B"],["thread-B"]] {
            var missing=CodexApprovals.ProtocolState(threadID:"thread-A",epoch:"fixture")
            _=try missing.receive(["id":"hud-fixture-initialize","result":Row()])
            XCTAssertThrowsError(try missing.receive(["id":"hud-fixture-loaded","result":["data":rows]]))
            XCTAssertEqual(missing.phase,"loaded")
        }
    }
    func testBridgeOverRealSyntheticWebSocketRespondsWithExactSemanticID()throws{
        let fixture=try CodexSocketTests.Fixture(mode:"approvals")
        let shown=expectation(description:"semantic card"),resolved=expectation(description:"exact ID resolved")
        var bridge:CodexApprovals!,answered=false,finished=false,token=""
        bridge=CodexApprovals(binary:"/unused-no-process-launched",socket:fixture.socket,threadID:"thread-A"){state in
            let cards=state["cards"] as! [Row]
            if !answered,let card=cards.first {
                answered=true;token=card["token"] as! String;shown.fulfill()
                do{try bridge.respond(token:token,choice:"session")}catch{XCTFail("Synthetic semantic response refused")}
            }else if answered,!finished,state["connected"] as? Bool == true,cards.isEmpty {
                finished=true;resolved.fulfill()
            }
        }
        bridge.connect();wait(for:[shown,resolved],timeout:8);bridge.disconnect()
        XCTAssertThrowsError(try bridge.respond(token:token,choice:"session"))
        withExtendedLifetime(fixture){}
    }

}
