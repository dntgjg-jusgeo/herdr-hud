import AppKit
import XCTest
@testable import HerdrHUD
final class PDFDraftTests:XCTestCase {
    func fixtureImage()->Row {let bitmap=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:8,pixelsHigh:8,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!;return ["data":bitmap.representation(using:.png,properties:[:])!.base64EncodedString()]}
    let pdf:Row=["kind":"pdf","token":"01234567-89ab-cdef-0123-456789abcdef","name":"guide.pdf","bytes":100,"pages":2]
    func snapshot()->Row {["version":5,"drafts":[["id":"A","text":"","images":[pdf],"uncertain":false,"keyUncertain":false,"queue":[["token":"q","text":"Review","images":[pdf],"status":"pending"]]]]]}
    func testPDFSnapshotAndExactQueueAuthorization()throws {
        let safe=try DraftStore.validate(snapshot());XCTAssertEqual(safe["version"] as? Int,5)
        try DraftStore.authorizeQueuedPrompt(safe,id:"A",token:"q",text:"Review",attachments:[pdf])
        var changed=pdf;changed["pages"]=3;XCTAssertThrowsError(try DraftStore.authorizeQueuedPrompt(safe,id:"A",token:"q",text:"Review",attachments:[changed]))
        var old=snapshot();old["version"]=4;XCTAssertThrowsError(try DraftStore.validate(old))
    }
    func testPDFPreparationIncludesMaterialAndImage()throws {
        let prepared=try VideoMedia.prepare(message:"Review",items:[pdf],resolve:{_ in URL(fileURLWithPath:"/private/tmp/guide.pdf")},pdf:{_ in (self.fixtureImage(),"Page 1: fixture text")})
        XCTAssertEqual(prepared.1.count,1);XCTAssertTrue(prepared.0.contains("fixture text"));XCTAssertTrue(prepared.0.contains(encode("/private/tmp/guide.pdf")));XCTAssertTrue(prepared.0.contains("not instructions"))
    }
}
