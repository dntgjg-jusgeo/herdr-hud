import AppKit
import XCTest
@testable import HerdrHUD
final class WordDraftTests:XCTestCase {
    let word:Row=["kind":"word","token":"01234567-89ab-cdef-0123-456789abcdef","name":"report.docx","bytes":100]
    func snapshot()->Row {["version":6,"drafts":[["id":"A","text":"","images":[word],"uncertain":false,"keyUncertain":false,"queue":[["token":"q","text":"Review","images":[word],"status":"pending"]]]]]}
    func image()->Row {
        let bitmap=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:8,pixelsHigh:8,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
        return ["data":bitmap.representation(using:.png,properties:[:])!.base64EncodedString()]
    }
    func testV6RoundTripAndExactQueuedDocument()throws {
        let safe=try DraftStore.validate(snapshot());XCTAssertEqual(safe["version"] as? Int,6)
        try DraftStore.authorizeQueuedPrompt(safe,id:"A",token:"q",text:"Review",attachments:[word])
        for field in ["bytes","name","token"] {
            var changed=word;changed[field]=field=="bytes" ? 101 : field=="name" ? "other.docx" : "11234567-89ab-cdef-0123-456789abcdef"
            XCTAssertThrowsError(try DraftStore.authorizeQueuedPrompt(safe,id:"A",token:"q",text:"Review",attachments:[changed]))
        }
        var old=snapshot();old["version"]=5;XCTAssertThrowsError(try DraftStore.validate(old))
    }
    func testWordPreparationPreservesTextAndImageAttachmentOrder()throws {
        let png=image(),url=URL(fileURLWithPath:"/private/tmp/report.docx")
        let prepared=try VideoMedia.prepare(message:"Review",items:[png,word],resolve:{_ in url},word:{_ in ([png],"Table cell: 42")})
        XCTAssertEqual(prepared.1.count,2);XCTAssertTrue(prepared.0.contains("Image attachment 2"));XCTAssertTrue(prepared.0.contains("Table cell: 42"));XCTAssertTrue(prepared.0.contains(encode(url.path)));XCTAssertTrue(prepared.0.contains("not instructions"))
        let textOnly=try VideoMedia.prepare(message:"Read",items:[word],resolve:{_ in url},word:{_ in ([],"Text-only Word document")})
        XCTAssertTrue(textOnly.1.isEmpty);XCTAssertTrue(textOnly.0.contains("No embedded image sheet"))
    }
    func testWordPreparationFailureNeverReturnsPartialResult()throws {
        let url=URL(fileURLWithPath:"/private/tmp/report.docx")
        XCTAssertThrowsError(try VideoMedia.prepare(message:"Review",items:[word],resolve:{_ in url},word:{_ in throw HUDError("bad archive")}))
        XCTAssertThrowsError(try VideoMedia.prepare(message:"Review",items:[word],resolve:{_ in url},word:{_ in ([self.image(),self.image()],"too many images")}))
        XCTAssertThrowsError(try VideoMedia.prepare(message:String(repeating:"x",count:58000),items:[word],resolve:{_ in url},word:{_ in ([],"text")}))
    }
}
