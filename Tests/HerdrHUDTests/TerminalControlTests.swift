import XCTest
@testable import HerdrHUD

final class TerminalControlTests: XCTestCase {
    func fixture(_ kind: String? = "permission", state: String = "blocked") -> HCTests.Fixture {
        let f = HCTests.Fixture()
        var terminal: Row = ["address":"t3","created_ms":100,"state":"live","cwd":"/fixture","foreground":["pid":123,"argv":["/fixture/codex"],"cwd":"/fixture"]]
        terminal["status"] = ["app":"codex","state":state,"kind":(kind as Any?) ?? NSNull()]
        f.terminals = [terminal]
        return f
    }
    func token(_ f: HCTests.Fixture, _ id: String) throws -> String {
        (try f.client.output(id)["terminalControl"] as! Row)["token"] as! String
    }
    func testOneFixedKeyUsesExactScreenAndConsumedPreview() throws {
        let f = fixture(), id = f.id(), preview = try token(f,id)
        XCTAssertEqual(try token(f,id),preview,"Unchanged polling preserves the unconsumed preview")
        XCTAssertThrowsError(try f.client.hc.terminalKey(id,token:preview,key:"1\nenter"))
        XCTAssertTrue(f.mutations.isEmpty)
        XCTAssertEqual(try f.client.hc.terminalKey(id,token:preview,key:"down")["ok"] as? Bool,true)
        XCTAssertEqual(f.mutations.count,1)
        let request = try JSONSerialization.jsonObject(with:f.mutations[0].input!) as! Row
        XCTAssertEqual(request["method"] as? String,"terminal.keys")
        let params = request["params"] as! Row
        XCTAssertEqual(params["keys"] as? [String],["down"]);XCTAssertEqual(params["terminal"] as? String,"t3")
        XCTAssertThrowsError(try f.client.hc.terminalKey(id,token:preview,key:"enter"))
        XCTAssertEqual(f.mutations.count,1)
        XCTAssertNotEqual(try token(f,id),preview)
    }
    func testStaleChangedReplacedAndExpiredPreviewsNeverMutate() throws {
        for mode in 0...5 {
            let f = fixture(), id = f.id(), preview = try token(f,id)
            if mode == 0 { f.screenText = "A different question" }
            if mode == 1 { f.terminals[0]["created_ms"] = 999 }
            if mode == 2 { f.terminals[0]["status"] = ["app":"codex","state":"idle","kind":"permission"] }
            if mode == 3 { f.terminals[0]["status"] = ["app":"codex","state":"blocked","kind":"auth"] }
            if mode == 4 { f.client.hc.keyPreviews[id] = HCClient.KeyPreview(token:preview,text:f.screenText,kind:"permission",date:Date(timeIntervalSinceNow:-16)) }
            if mode == 5 { f.screenHow = "stitched" }
            XCTAssertThrowsError(try f.client.hc.terminalKey(id,token:preview,key:"enter"))
            XCTAssertTrue(f.mutations.isEmpty)
        }
    }
    func testUnsupportedStatusOrPartialScreenDoesNotOfferControls() throws {
        for kind in [nil,"auth",""] as [String?] {
            let f = fixture(kind), id = f.id();XCTAssertNil(try f.client.output(id)["terminalControl"])
        }
        let f = fixture(), id = f.id();f.screenComplete = false
        XCTAssertThrowsError(try f.client.output(id));XCTAssertTrue(f.mutations.isEmpty)
        for state in ["idle","working","done","unknown"] {
            let f = fixture(state:state), id = f.id();XCTAssertNil(try f.client.output(id)["terminalControl"])
        }
    }
    func testUncertainKeyLocksUntilExplicitReconciliationAndNeverRetries() throws {
        let f = fixture("question"), id = f.id(), preview = try token(f,id);f.sendError = true
        XCTAssertThrowsError(try f.client.hc.terminalKey(id,token:preview,key:"esc"))
        XCTAssertEqual(f.mutations.count,1)
        let next = try token(f,id)
        XCTAssertThrowsError(try f.client.hc.terminalKey(id,token:next,key:"esc"));XCTAssertEqual(f.mutations.count,1)
        try f.client.hc.reconcileTerminalKeys(id);f.sendError = false
        XCTAssertThrowsError(try f.client.hc.terminalKey(id,token:next,key:"esc"))
        _ = try f.client.hc.terminalKey(id,token:token(f,id),key:"esc")
        XCTAssertEqual(f.mutations.count,2)
    }
    let menu = """
    Field 1/1
    Allow Computer Use to use "Fixture"?
    App: Fixture
    > 1. Allow  Run the tool and continue
    2. Allow for this session  Run the tool and remember
    3. Always allow  Run the tool and remember
    4. Cancel  Cancel this tool call
    enter to submit | esc to cancel
    """
    func testGuardedNumberKeysAreSingleUseAndNeverFallBack() throws {
        for outcome in ["written","rejected","uncertain","lost"] {
            let f=fixture();f.features=["guarded_keys_v1"];f.screenText=menu
            let id=f.id(),control=try f.client.output(id)["terminalControl"] as! Row
            XCTAssertEqual((control["choices"] as? [Row])?.count,4)
            f.checkedResult=["outcome":outcome];f.sendError=outcome=="lost"
            if ["written","rejected"].contains(outcome) {
                let result=try f.client.hc.approvalChoice(id,token:control["choiceToken"] as! String,key:"2")
                XCTAssertEqual(result["ok"] as? Bool,outcome=="written" ? true:nil)
                XCTAssertFalse(f.client.hc.uncertainKeys.contains(id))
            } else {
                XCTAssertThrowsError(try f.client.hc.approvalChoice(id,token:control["choiceToken"] as! String,key:"2"))
                XCTAssertTrue(f.client.hc.uncertainKeys.contains(id))
                XCTAssertThrowsError(try f.client.hc.reconcileTerminalKeys(id))
            }
            XCTAssertEqual(f.mutations.count,1)
            let request=try JSONSerialization.jsonObject(with:f.mutations[0].input!) as! Row
            XCTAssertEqual(request["method"] as? String,"terminal.keys_checked")
            XCTAssertEqual((request["params"] as! Row)["key"] as? String,"2")
            XCTAssertThrowsError(try f.client.hc.approvalChoice(id,token:"guarded-token",key:"2"))
            XCTAssertEqual(f.mutations.count,1)
        }
    }
    func testGuardedControlsRequireCapabilityIdentityAndRecognizedScreen() throws {
        for mode in 0...3 {
            let f=fixture();f.screenText=menu
            if mode != 0 { f.features=["guarded_keys_v1"] }
            if mode==1 { f.snapshotCore="other-core" }
            if mode==2 { f.screenText=menu+"\nNew question" }
            if mode==3 { f.screenText=menu.replacingOccurrences(of:"Field 1/1",with:"Field 1/2") }
            let id=f.id(),control=try f.client.output(id)["terminalControl"] as! Row
            XCTAssertNil(control["choiceToken"]);XCTAssertTrue(f.mutations.isEmpty)
        }
    }

}
