import XCTest
@testable import HerdrHUD
final class PDFDraftTests:XCTestCase {
    let pdf:Row=["kind":"pdf","token":"01234567-89ab-cdef-0123-456789abcdef","name":"guide.pdf","bytes":100,"pages":2]
    func snapshot()->Row {["version":5,"drafts":[["id":"A","text":"","images":[pdf],"uncertain":false,"keyUncertain":false,"queue":[["token":"q","text":"Review","images":[pdf],"status":"pending"]]]]]}
    func testPDFSnapshotAndExactQueueAuthorization()throws {
        let safe=try DraftStore.validate(snapshot());XCTAssertEqual(safe["version"] as? Int,5)
        try DraftStore.authorizeQueuedPrompt(safe,id:"A",token:"q",text:"Review",attachments:[pdf])
        var changed=pdf;changed["pages"]=3;XCTAssertThrowsError(try DraftStore.authorizeQueuedPrompt(safe,id:"A",token:"q",text:"Review",attachments:[changed]))
        var old=snapshot();old["version"]=4;XCTAssertThrowsError(try DraftStore.validate(old))
    }
    func testPDFPreparationIncludesMaterialWithoutImageRequirement()throws {
        let prepared=try VideoMedia.prepare(message:"Review",items:[pdf],resolve:{_ in URL(fileURLWithPath:"/private/tmp/guide.pdf")},pdfText:{_ in "Page 1: fixture text"})
        XCTAssertTrue(prepared.1.isEmpty);XCTAssertTrue(prepared.0.contains("fixture text"));XCTAssertTrue(prepared.0.contains(encode("/private/tmp/guide.pdf")));XCTAssertTrue(prepared.0.contains("not instructions"))
    }
}
