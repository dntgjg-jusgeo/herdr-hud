import XCTest
import AppKit
import PDFKit
import CoreText
import Darwin
@testable import HerdrHUD

final class PDFAttachmentsTests:XCTestCase {
    func folder()->URL{URL(fileURLWithPath:"/private/tmp",isDirectory:true).appendingPathComponent("hud-pdf-tests-"+UUID().uuidString,isDirectory:true)}
    func fixture(pages:Int=2,text:String="Embedded PDF fixture")throws->Data {
        let data=NSMutableData(),consumer=try XCTUnwrap(CGDataConsumer(data:data))
        var rect=CGRect(x:0,y:0,width:400,height:500)
        let context=try XCTUnwrap(CGContext(consumer:consumer,mediaBox:&rect,nil))
        for page in 1...pages {
            context.beginPDFPage(nil);context.textPosition=CGPoint(x:20,y:450)
            let characters=Array("\(text) page \(page)")
            for offset in stride(from:0,to:min(characters.count,1560),by:60) {
                context.textPosition=CGPoint(x:20,y:450-(offset/60)*16)
                let string=NSAttributedString(string:String(characters[offset..<min(offset+60,characters.count)]),attributes:[.font:NSFont.systemFont(ofSize:14)])
                CTLineDraw(CTLineCreateWithAttributedString(string),context)
            }
            context.endPDFPage()
        }
        context.closePDF();return data as Data
    }
    func testRealPDFRoundtripPrivateCacheAndRestart()throws {
        let root=folder();defer{try? FileManager.default.removeItem(at:root)}
        let source=root.appendingPathComponent("source.pdf"),cache=root.appendingPathComponent("cache")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let bytes=try fixture();try bytes.write(to:source)
        if let path=ProcessInfo.processInfo.environment["HERDR_PDF_FIXTURE_DIR"] {
            let export=URL(fileURLWithPath:path,isDirectory:true)
            try FileManager.default.createDirectory(at:export,withIntermediateDirectories:true)
            try bytes.write(to:export.appendingPathComponent("HUD-guide.pdf"))
        }
        let row=try PDFAttachments(directory:cache).importFile(source)
        XCTAssertEqual(row["pages"] as? Int,2);XCTAssertEqual(row["bytes"] as? Int,bytes.count)
        let store=PDFAttachments(directory:cache),url=try store.reference(row)
        try FileManager.default.removeItem(at:source)
        XCTAssertEqual(try Data(contentsOf:url),bytes)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath:url.path)[.posixPermissions] as? NSNumber)?.intValue,0o600)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath:cache.path)[.posixPermissions] as? NSNumber)?.intValue,0o700)
        let material=PDFAttachments.promptMaterial(url:url)
        XCTAssertTrue(material.contains("[Page 1 of 2]"));XCTAssertTrue(material.contains("[Page 2 of 2]"))
        XCTAssertTrue(material.contains("Embedded PDF fixture"));XCTAssertTrue(material.contains("no OCR"));XCTAssertTrue(material.contains(encode(url.path)))
    }
    func testSameLengthTamperIsRejectedOnlyOnFullVerification()throws {
        let root=folder();defer{try? FileManager.default.removeItem(at:root)}
        let store=PDFAttachments(directory:root),bytes=try fixture()
        let row=try store.importData(name:"test.pdf",dataBase64:bytes.base64EncodedString()),url=try store.reference(row)
        try Data(repeating:0,count:bytes.count).write(to:url)
        XCTAssertNoThrow(try store.reference(row,verifyContent:false))
        XCTAssertThrowsError(try store.reference(row))
        var wrong=row;wrong["pages"]=3;XCTAssertThrowsError(try store.reference(wrong,verifyContent:false))
    }
    func testInvalidEncryptedAndBounds()throws {
        let root=folder();defer{try? FileManager.default.removeItem(at:root)}
        let store=PDFAttachments(directory:root),bytes=try fixture()
        for name in [".pdf","../test.pdf","test.txt","test\n.pdf",String(repeating:"a",count:117)+".pdf"] {
            XCTAssertThrowsError(try store.importData(name:name,dataBase64:bytes.base64EncodedString()))
        }
        for data in [Data(),Data("%PDF-1.7\nnot a document".utf8),Data(repeating:0,count:PDFAttachments.maximumBytes+1)] {
            XCTAssertThrowsError(try store.importData(name:"test.pdf",dataBase64:data.base64EncodedString()))
        }
        let document=try XCTUnwrap(PDFDocument(data:bytes))
        let encrypted=try XCTUnwrap(document.dataRepresentation(options:[PDFDocumentWriteOption.ownerPasswordOption:"owner",PDFDocumentWriteOption.userPasswordOption:"secret"]))
        XCTAssertTrue(try XCTUnwrap(PDFDocument(data:encrypted)).isEncrypted)
        XCTAssertThrowsError(try store.importData(name:"locked.pdf",dataBase64:encrypted.base64EncodedString()))
        XCTAssertThrowsError(try store.importData(name:"many.pdf",dataBase64:fixture(pages:201).base64EncodedString()))
        var row:Row=["kind":"pdf","token":UUID().uuidString.lowercased(),"name":"test.pdf","bytes":1,"pages":1]
        row["bytes"]=true;XCTAssertThrowsError(try PDFAttachments.validateReference(row))
        row["bytes"]=1;row["pages"]=201;XCTAssertThrowsError(try PDFAttachments.validateReference(row))
        row["pages"]=1;row["token"]="../../escape";XCTAssertThrowsError(try PDFAttachments.validateReference(row))
    }
    func testSymlinksAndQuotaRetainFinalAssets()throws {
        let root=folder();defer{try? FileManager.default.removeItem(at:root)}
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let source=root.appendingPathComponent("source.pdf"),link=root.appendingPathComponent("link.pdf"),cache=root.appendingPathComponent("cache")
        let bytes=try fixture();try bytes.write(to:source)
        try FileManager.default.createSymbolicLink(at:link,withDestinationURL:source)
        let store=PDFAttachments(directory:cache)
        XCTAssertThrowsError(try store.importFile(link))
        let row=try store.importFile(source),url=try store.reference(row)
        let cacheLink=root.appendingPathComponent("cache-link")
        try FileManager.default.createSymbolicLink(at:cacheLink,withDestinationURL:cache)
        XCTAssertThrowsError(try PDFAttachments(directory:cacheLink).importFile(source))
        let fill=cache.appendingPathComponent("quota.bin"),fd=open(fill.path,O_WRONLY|O_CREAT|O_EXCL,0o600)
        XCTAssertGreaterThanOrEqual(fd,0);XCTAssertEqual(ftruncate(fd,off_t(PDFAttachments.maximumCacheBytes)),0);close(fd)
        XCTAssertThrowsError(try store.importFile(source));XCTAssertNoThrow(try store.reference(row))
        try FileManager.default.removeItem(at:fill)
        try FileManager.default.removeItem(at:url);try FileManager.default.createSymbolicLink(at:url,withDestinationURL:source)
        XCTAssertThrowsError(try store.reference(row))
    }
    func testExtractedTextBudgetAndHonestTruncation()throws {
        let root=folder();defer{try? FileManager.default.removeItem(at:root)}
        let store=PDFAttachments(directory:root),bytes=try fixture(pages:30,text:String(repeating:"PDF text ",count:300))
        let row=try store.importData(name:"long.pdf",dataBase64:bytes.base64EncodedString()),url=try store.reference(row)
        let material=PDFAttachments.promptMaterial(url:url)
        XCTAssertLessThanOrEqual(material.utf8.count,16000);XCTAssertTrue(material.contains("excerpt truncated"))
        XCTAssertTrue(material.contains("Images, diagrams and scanned pages have not been analyzed"))
    }
}
