import XCTest
import AppKit
import CoreText
import PDFKit
@testable import HerdrHUD

final class PDFAnalysisTests:XCTestCase {
    func drawText(_ text:String,_ context:CGContext,y:CGFloat) {
        let label=NSAttributedString(string:text,attributes:[NSAttributedString.Key(kCTFontAttributeName as String):CTFontCreateWithName("Helvetica-Bold" as CFString,32,nil),NSAttributedString.Key(kCTForegroundColorAttributeName as String):CGColor(gray:0,alpha:1)])
        context.textPosition=CGPoint(x:36,y:y);CTLineDraw(CTLineCreateWithAttributedString(label),context)
    }
    func fixture(pages:Int = 3)throws->Data {
        let data=NSMutableData(),consumer=CGDataConsumer(data:data as CFMutableData)!
        var bounds=CGRect(x:0,y:0,width:612,height:792)
        let context=CGContext(consumer:consumer,mediaBox:&bounds,nil)!
        for index in 0..<pages {
            context.beginPDFPage(nil)
            if index != 1 {drawText(index==0 ? "EMBEDDED ORCHID 314" : "MIXED HEADER 271",context,y:700)}
            if index>0 {
                let scan=CGContext(data:nil,width:612,height:500,bitsPerComponent:8,bytesPerRow:612*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.noneSkipLast.rawValue)!
                scan.setFillColor(CGColor(gray:1,alpha:1));scan.fill(CGRect(x:0,y:0,width:612,height:500))
                drawText(index==1 ? "SCANNED FALCON 582" : "RASTER COBALT 963",scan,y:400)
                scan.setFillColor(CGColor(red:1,green:0,blue:0,alpha:1))
                scan.move(to:CGPoint(x:230,y:90));scan.addLine(to:CGPoint(x:380,y:90));scan.addLine(to:CGPoint(x:305,y:240));scan.closePath();scan.fillPath()
                context.draw(scan.makeImage()!,in:CGRect(x:0,y:100,width:612,height:500))
            }
            context.endPDFPage()
        }
        context.closePDF();return data as Data
    }
    func testAllPagesOCRAndMixedRasterWithActualVision()throws {
        let export=ProcessInfo.processInfo.environment["HERDR_PDF_ANALYSIS_FIXTURE_DIR"]
        let root=export.map{URL(fileURLWithPath:$0,isDirectory:true)} ?? URL(fileURLWithPath:"/private/tmp",isDirectory:true).appendingPathComponent(UUID().uuidString,isDirectory:true)
        defer{if export == nil {try? FileManager.default.removeItem(at:root)}}
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:root.path)
        let store=PDFAttachments(directory:root.appendingPathComponent("private",isDirectory:true))
        let bytes=try fixture(),item=try store.importData(name:"mixed-scanned-fixture.pdf",dataBase64:bytes.base64EncodedString()),url=try store.reference(item)
        let result=try VideoMedia.prepare(message:"Review the PDF",items:[item],resolve:{_ in url})
        XCTAssertEqual(result.1.count,1)
        let delivered=NSBitmapImageRep(data:Data(base64Encoded:result.1[0]["data"] as! String)!)!
        XCTAssertLessThanOrEqual(max(delivered.pixelsWide,delivered.pixelsHigh),2000)
        let transcript=try String(contentsOf:url.deletingPathExtension().appendingPathExtension("analysis.txt"),encoding:.utf8)
        XCTAssertTrue(transcript.contains("EMBEDDED ORCHID 314"));XCTAssertTrue(transcript.contains("SCANNED FALCON 582"));XCTAssertTrue(transcript.contains("RASTER COBALT 963"));XCTAssertTrue(transcript.contains("MIXED HEADER 271"))
        XCTAssertEqual(transcript.components(separatedBy:"Apple Vision OCR (entire rendered page):").count-1,3)
        XCTAssertTrue(result.0.contains("All 3 pages rendered and OCR processed"));XCTAssertTrue(result.0.contains("sampled visual coverage"))
        try Data(base64Encoded:result.1[0]["data"] as! String)!.write(to:root.appendingPathComponent("sheet.jpg"))
        try result.0.write(to:root.appendingPathComponent("material.txt"),atomically:true,encoding:.utf8)
        try transcript.write(to:root.appendingPathComponent("transcript.txt"),atomically:true,encoding:.utf8)
        try bytes.write(to:root.appendingPathComponent("fixture.pdf"))
        try "Page1 embedded EMBEDDED ORCHID 314; page2 raster SCANNED FALCON 582 + red triangle; page3 embedded MIXED HEADER 271 + raster RASTER COBALT 963 + red triangle.\n".write(to:root.appendingPathComponent("ground-truth.txt"),atomically:true,encoding:.utf8)
    }
    func testEveryPageRecognizedEvenWithEmbeddedTextAndSampling()throws {
        let root=URL(fileURLWithPath:"/private/tmp",isDirectory:true).appendingPathComponent(UUID().uuidString,isDirectory:true)
        defer{try? FileManager.default.removeItem(at:root)}
        let store=PDFAttachments(directory:root),item=try store.importData(name:"test.pdf",dataBase64:fixture(pages:8).base64EncodedString()),url=try store.reference(item)
        var calls=0
        let result=try PDFAnalysis.prepare(url:url,ocr:{image in calls+=1;XCTAssertLessThanOrEqual(max(image.width,image.height),2000);return "RASTER PAGE \(calls)"})
        let delivered=NSBitmapImageRep(data:Data(base64Encoded:result.image["data"] as! String)!)!
        XCTAssertLessThanOrEqual(max(delivered.pixelsWide,delivered.pixelsHigh),2000)
        XCTAssertEqual(calls,8);XCTAssertTrue(result.summary.contains("6 of 8 pages"))
        XCTAssertThrowsError(try PDFAnalysis.prepare(url:url,ocr:{_ in XCTFail("OCR should not run after deadline");return ""},timeLimit:0))
        XCTAssertEqual(PDFAnalysis.samplePages(count:200),[0,40,80,119,159,199])
        XCTAssertThrowsError(try PDFAnalysis.prepare(url:url,ocr:{_ in throw HUDError("synthetic OCR failure")}))
        XCTAssertThrowsError(try PDFAnalysis.prepare(url:url,ocr:{_ in String(repeating:"x",count:PDFAnalysis.maximumTranscriptBytes+1)}))
    }
    func testTranscriptSymlinkIsRejected()throws {
        let root=URL(fileURLWithPath:"/private/tmp",isDirectory:true).appendingPathComponent(UUID().uuidString,isDirectory:true)
        defer{try? FileManager.default.removeItem(at:root)}
        let store=PDFAttachments(directory:root),item=try store.importData(name:"test.pdf",dataBase64:fixture().base64EncodedString()),url=try store.reference(item)
        let target=root.appendingPathComponent("untouched.txt")
        try "untouched".write(to:target,atomically:true,encoding:.utf8)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:target.path)
        try FileManager.default.createSymbolicLink(at:url.deletingPathExtension().appendingPathExtension("analysis.txt"),withDestinationURL:target)
        XCTAssertThrowsError(try PDFAnalysis.prepare(url:url,ocr:{_ in "fixture"}))
        XCTAssertEqual(try String(contentsOf:target,encoding:.utf8),"untouched")
    }
    func testExcerptOverflowKeepsFullArtifact()throws {
        let root=URL(fileURLWithPath:"/private/tmp",isDirectory:true).appendingPathComponent(UUID().uuidString,isDirectory:true)
        defer{try? FileManager.default.removeItem(at:root)}
        let store=PDFAttachments(directory:root),item=try store.importData(name:"long.pdf",dataBase64:fixture().base64EncodedString()),url=try store.reference(item)
        let result=try PDFAnalysis.prepare(url:url,ocr:{_ in String(repeating:"Long OCR line. ",count:2000)})
        XCTAssertTrue(result.summary.contains("truncated, read full artifact"))
        let text=try String(contentsOf:url.deletingPathExtension().appendingPathExtension("analysis.txt"),encoding:.utf8)
        XCTAssertGreaterThan(text.utf8.count,PDFAnalysis.excerptBytes)
        let attributes=try FileManager.default.attributesOfItem(atPath:url.deletingPathExtension().appendingPathExtension("analysis.txt").path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue,0o600)
    }
}
