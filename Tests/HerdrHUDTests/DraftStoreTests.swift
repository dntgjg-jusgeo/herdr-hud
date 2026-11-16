import AppKit
import XCTest
@testable import HerdrHUD

final class DraftStoreTests: XCTestCase {
    func folder() -> URL { URL(fileURLWithPath:"/private/tmp",isDirectory:true).appendingPathComponent("hud-drafts-tests-"+UUID().uuidString,isDirectory:true) }
    func snapshot(_ text:String = "private draft") -> Row {
        let image = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:4,pixelsHigh:4,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!.representation(using:.png,properties:[:])!
        return ["version":1,"drafts":[["id":"exact-agent-identity","label":"A task","text":text,"images":[["name":"original.png","data":image.base64EncodedString()]],"uncertain":true,"keyUncertain":true]]]
    }
    func testPrivateRoundTripAndExplicitClear() throws {
        let url=folder();defer { try? FileManager.default.removeItem(at:url) }
        let store=DraftStore(directory:url)
        XCTAssertThrowsError(try store.save(snapshot()))
        XCTAssertEqual((try store.load()["drafts"] as? [Row])?.count,0)
        try store.save(snapshot())
        let fresh=DraftStore(directory:url),rows=try XCTUnwrap(try fresh.load()["drafts"] as? [Row])
        XCTAssertEqual(rows[0]["id"] as? String,"exact-agent-identity");XCTAssertEqual(rows[0]["text"] as? String,"private draft")
        XCTAssertEqual(rows[0]["uncertain"] as? Bool,true);XCTAssertEqual(rows[0]["keyUncertain"] as? Bool,true)
        XCTAssertEqual((rows[0]["images"] as? [Row])?[0]["name"] as? String,"original.png")
        let fm=FileManager.default
        XCTAssertEqual((try fm.attributesOfItem(atPath:url.path)[.posixPermissions] as? NSNumber)?.intValue,0o700)
        XCTAssertEqual((try fm.attributesOfItem(atPath:url.appendingPathComponent("snapshot.json").path)[.posixPermissions] as? NSNumber)?.intValue,0o600)
        try fresh.save(["version":1,"drafts":[Row]()]);XCTAssertEqual((try DraftStore(directory:url).load()["drafts"] as? [Row])?.count,0)
    }
    func testCorruptSnapshotRetainedAndNeverOverwritten() throws {
        let url=folder();defer { try? FileManager.default.removeItem(at:url) }
        let store=DraftStore(directory:url);_=try store.load()
        let file=url.appendingPathComponent("snapshot.json"),bad=Data("{broken".utf8)
        try bad.write(to:file)
        XCTAssertThrowsError(try store.load());XCTAssertThrowsError(try store.save(snapshot()))
        XCTAssertEqual(try Data(contentsOf:file),bad)
    }
    func testSymlinkTargetAndStoreAreRefusedWithoutTouchingDestination() throws {
        let url=folder(),outside=folder();defer { try? FileManager.default.removeItem(at:url);try? FileManager.default.removeItem(at:outside) }
        try FileManager.default.createDirectory(at:outside,withIntermediateDirectories:true)
        let external=outside.appendingPathComponent("keep"),data=Data("untouched".utf8);try data.write(to:external)
        let store=DraftStore(directory:url);_=try store.load()
        try FileManager.default.createSymbolicLink(at:url.appendingPathComponent("snapshot.json"),withDestinationURL:external)
        XCTAssertThrowsError(try store.save(snapshot()));XCTAssertThrowsError(try store.load());XCTAssertEqual(try Data(contentsOf:external),data)
        try FileManager.default.removeItem(at:url)
        try FileManager.default.createSymbolicLink(at:url,withDestinationURL:outside)
        XCTAssertThrowsError(try DraftStore(directory:url).load())
        XCTAssertThrowsError(try DraftStore(directory:url.appendingPathComponent("child")).load())
    }
    func testBoundsAndRasterValidationPreserveLastSnapshot() throws {
        let url=folder();defer { try? FileManager.default.removeItem(at:url) }
        let store=DraftStore(directory:url);_=try store.load();try store.save(snapshot("original"))
        XCTAssertThrowsError(try store.save(snapshot(String(repeating:"x",count:60001))))
        var invalid=snapshot(),rows=invalid["drafts"] as! [Row]
        rows[0]["images"]=[["name":"bad.svg","data":Data("<svg/>".utf8).base64EncodedString()]];invalid["drafts"]=rows
        XCTAssertThrowsError(try store.save(invalid))
        XCTAssertEqual((try DraftStore(directory:url).load()["drafts"] as? [Row])?[0]["text"] as? String,"original")
    }
    func queued(_ token: String, text: String = "Next task", status: String = "queued", images: [Row] = []) -> Row {
        ["token":token,"text":text,"images":images,"status":status]
    }
    func queueSnapshot(_ queue: [Row], id: String = "exact-agent-identity", text: String = "") -> Row {
        ["version":1,"drafts":[["id":id,"label":"Queued task","text":text,"images":[Row](),"uncertain":false,"keyUncertain":false,"queue":queue]]]
    }
    func testQueuedOnlySnapshotRoundTripPreservesFIFOAndPendingIntentBecomesUncertain() throws {
        let url=folder();defer { try? FileManager.default.removeItem(at:url) }
        let image=((snapshot()["drafts"] as! [Row])[0]["images"] as! [Row])[0]
        let store=DraftStore(directory:url);_=try store.load()
        try store.save(queueSnapshot([queued("first",status:"pending",images:[image]),queued("second")]))
        let restored=try DraftStore(directory:url).load(),rows=restored["drafts"] as! [Row],queue=rows[0]["queue"] as! [Row]
        XCTAssertEqual(restored["version"] as? Int,2)
        XCTAssertEqual(rows[0]["text"] as? String,"");XCTAssertEqual(queue.map { $0["token"] as! String },["first","second"])
        XCTAssertEqual(queue[0]["status"] as? String,"uncertain");XCTAssertEqual(queue[1]["status"] as? String,"queued")
        XCTAssertEqual((queue[0]["images"] as? [Row])?[0]["data"] as? String,image["data"] as? String)
    }
    func testQueueBoundsAndDuplicateTokensShareTheDraftBudget() throws {
        XCTAssertThrowsError(try DraftStore.validate(["version":true,"drafts":[Row]()]));XCTAssertThrowsError(try DraftStore.validate(["version":2.5,"drafts":[Row]()]))
        XCTAssertThrowsError(try DraftStore.validate(queueSnapshot((0..<17).map { queued("entry-\($0)") })))
        var duplicate=queueSnapshot([queued("same")]),rows=duplicate["drafts"] as! [Row]
        var second=rows[0];second["id"]="another-exact-session";rows.append(second);duplicate["drafts"]=rows
        XCTAssertThrowsError(try DraftStore.validate(duplicate))
        let large=(0..<16).map { queued("large-\($0)",text:String(repeating:"x",count:60000)) }
        var combined=queueSnapshot(large,text:String(repeating:"y",count:60000)),combinedRows=combined["drafts"] as! [Row]
        combinedRows.append(["id":"claude-exact-session","label":"Claude","text":String(repeating:"z",count:60000),"images":[Row](),"uncertain":false,"keyUncertain":false]);combined["drafts"]=combinedRows
        XCTAssertThrowsError(try DraftStore.validate(combined))
        XCTAssertThrowsError(try DraftStore.validate(queueSnapshot([queued("empty",text:"")])))
        XCTAssertThrowsError(try DraftStore.validate(queueSnapshot([queued("bad",status:"complete")])))
    }
    func testBackgroundAuthorizationRequiresExactSavedUncertainHeadAndPayload() throws {
        let image=((snapshot()["drafts"] as! [Row])[0]["images"] as! [Row])[0]
        let saved=queueSnapshot([queued("first",text:"Original follow-up",status:"pending",images:[image]),queued("second")])
        let payload:[[String:Any]]=[["data":image["data"]!]]
        XCTAssertNoThrow(try DraftStore.authorizeQueuedPrompt(saved,id:"exact-agent-identity",token:"first",text:"Original follow-up",attachments:payload))
        for (id,token,text,images) in [("replacement","first","Original follow-up",payload),("exact-agent-identity","second","Original follow-up",payload),("exact-agent-identity","first","Changed",payload),("exact-agent-identity","first","Original follow-up",[Row]())] {
            XCTAssertThrowsError(try DraftStore.authorizeQueuedPrompt(saved,id:id,token:token,text:text,attachments:images))
        }
        XCTAssertThrowsError(try DraftStore.authorizeQueuedPrompt(queueSnapshot([queued("queued")]),id:"exact-agent-identity",token:"queued",text:"Next task",attachments:nil))
        XCTAssertThrowsError(try DraftStore.authorizeQueuedPrompt(saved,id:"exact-agent-identity",token:"first",text:"Original follow-up",attachments:[["data":"different"]]))
    }

}
