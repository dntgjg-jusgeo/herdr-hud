import AppKit
import XCTest
@testable import HerdrHUD

final class AttachmentTests: XCTestCase {
    func image() -> Data {
        NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:4,pixelsHigh:4,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!.representation(using:.png,properties:[:])!
    }
    func testRasterValidationAndSafeGeneratedNames() throws {
        let rows: [Row] = [["data":image().base64EncodedString(),"name":"../../unsafe$(data).svg"]]
        let attachments = try ImageAttachment.parse(rows)
        XCTAssertEqual(attachments.count,1);XCTAssertTrue(attachments[0].name.hasPrefix("hud-image-"));XCTAssertTrue(attachments[0].name.hasSuffix(".png"))
        XCTAssertThrowsError(try ImageAttachment.parse([["data":Data("<svg/>".utf8).base64EncodedString()]]))
        XCTAssertThrowsError(try ImageAttachment.parse([["data":String(repeating:"A",count:6*1024*1024)]]))
        XCTAssertThrowsError(try ImageAttachment.parse(Array(repeating:rows[0],count:4)))
        XCTAssertThrowsError(try ImageAttachment.parse("not an array"))
    }
    func testUploadThenSingleSendWithFreshIdentityChecksAndStdinOnly() throws {
        let f=HCTests.Fixture();f.terminals=[HCTests().terminal()];let id=f.id()
        let images=try ImageAttachment.parse([["data":image().base64EncodedString()]])
        _=try f.client.hc.prompt(id,"Look at this",attachments:images)
        XCTAssertEqual(f.mutations.count,2)
        let requests=try f.mutations.map { try JSONSerialization.jsonObject(with:$0.input!) as! Row }
        XCTAssertEqual(requests.map { $0["method"] as! String },["terminal.put","terminal.send"])
        let send=requests[1]["params"] as! Row
        XCTAssertTrue((send["text"] as! String).contains("Inspect these local image files"))
        XCTAssertTrue((send["text"] as! String).contains(encode("/fixture/image.png")))
        XCTAssertEqual(f.mutations[0].maximumInputBytes,6*1024*1024);XCTAssertEqual(f.mutations[1].maximumInputBytes,524288)
        XCTAssertTrue(f.mutations.allSatisfy { $0.arguments == ["connect","--session","default"] })
        let methods=try f.calls.flatMap { call in try String(decoding:call.input!,as:UTF8.self).split(separator:"\n").map { (try JSONSerialization.jsonObject(with:Data($0.utf8)) as! Row)["method"] as! String } }
        XCTAssertEqual(methods.filter { $0 == "terminal.get" }.count,3)
    }
    func testImageOnlySendAndBusyAfterUploadNeverSends() throws {
        let f=HCTests.Fixture();f.terminals=[HCTests().terminal()];let id=f.id()
        let images=try ImageAttachment.parse([["data":image().base64EncodedString()]])
        f.afterPut={ f.terminals=[HCTests().terminal("working")] }
        XCTAssertThrowsError(try f.client.hc.prompt(id,"",attachments:images)) { XCTAssertTrue($0.localizedDescription.contains("uncertain")) }
        XCTAssertEqual(f.mutations.count,1)
        f.afterPut=nil;f.terminals=[HCTests().terminal()]
        _=try f.client.hc.prompt(id,"",attachments:images)
        XCTAssertEqual(f.mutations.count,3)
    }
    func testUploadAcknowledgementAndPostUploadReplacementNeverRetry() throws {
        let images=try ImageAttachment.parse([["data":image().base64EncodedString()]])
        for mode in 0...2 {
            let f=HCTests.Fixture();f.terminals=[HCTests().terminal()];let id=f.id()
            if mode == 0 { f.putResult=["path":"relative.png","bytes":images[0].data.count] }
            if mode == 1 { f.afterPut={ f.terminals=[HCTests().terminal(pid:456)] } }
            if mode == 2 { f.sendError=true }
            XCTAssertThrowsError(try f.client.hc.prompt(id,"inspect",attachments:images)) { XCTAssertTrue($0.localizedDescription.contains("uncertain")) }
            XCTAssertEqual(f.mutations.count,mode == 2 ? 2 : 1)
        }
    }
    func testRemoteAndReplacedTerminalNeverUpload() throws {
        let images=try ImageAttachment.parse([["data":image().base64EncodedString()]])
        let f=HCTests.Fixture();f.machines=[["id":"remote","name":"worker","state":"connected","target":"fixture"]];f.terminals=[HCTests().terminal(address:"worker/t7")];let id=f.id()
        XCTAssertThrowsError(try f.client.hc.prompt(id,"inspect",attachments:images));XCTAssertTrue(f.mutations.isEmpty)
        let local=HCTests.Fixture();local.terminals=[HCTests().terminal()];let selected=local.id();local.terminals=[HCTests().terminal(pid:456)]
        XCTAssertThrowsError(try local.client.hc.prompt(selected,"inspect",attachments:images));XCTAssertTrue(local.mutations.isEmpty)
    }
}
