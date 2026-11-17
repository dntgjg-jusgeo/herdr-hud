import XCTest
import AppKit
import Compression
import Darwin
@testable import HerdrHUD

final class WordNativeTests:XCTestCase {
    func zip(_ entries:[(String,Data)],deflate:Bool=false)->Data {
        func n(_ value:Int,_ count:Int)->Data {Data((0..<count).map{UInt8(truncatingIfNeeded:value>>($0*8))})}
        var output=Data(),central=Data()
        for (name,data) in entries {
            let filename=Data(name.utf8),offset=output.count,crc=Int(WordPackage.crc(data))
            var packed=data
            if deflate {
                var buffer=[UInt8](repeating:0,count:data.count*2+1024)
                let size=data.withUnsafeBytes {raw in compression_encode_buffer(&buffer,buffer.count,raw.bindMemory(to:UInt8.self).baseAddress!,data.count,nil,COMPRESSION_ZLIB)}
                packed=Data(buffer.prefix(size))
            }
            let method=deflate ? 8:0
            output+=n(0x04034b50,4)
            output+=n(20,2)
            output+=n(0,2)
            output+=n(method,2)
            output+=n(0,4)
            output+=n(crc,4)
            output+=n(packed.count,4)
            output+=n(data.count,4)
            output+=n(filename.count,2)
            output+=n(0,2)
            output+=filename
            output+=packed
            central+=n(0x02014b50,4)
            central+=n(20,2)
            central+=n(20,2)
            central+=n(0,2)
            central+=n(method,2)
            central+=n(0,4)
            central+=n(crc,4)
            central+=n(packed.count,4)
            central+=n(data.count,4)
            central+=n(filename.count,2)
            central+=n(0,2)
            central+=n(0,2)
            central+=n(0,2)
            central+=n(0,2)
            central+=n(0,4)
            central+=n(offset,4)
            central+=filename
        }
        let offset=output.count;output+=central
        output+=n(0x06054b50,4)
        output+=n(0,4)
        output+=n(entries.count,2)
        output+=n(entries.count,2)
        output+=n(central.count,4)
        output+=n(offset,4)
        output+=n(0,2)
        return output
    }
    func entries(image:Bool=true)throws->[(String,Data)] {
        var entries:[(String,Data)]=[
            ("[Content_Types].xml",Data("<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/><Override PartName=\"/word/header1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.header+xml\"/><Default Extension=\"png\" ContentType=\"image/png\"/><Override PartName=\"/word/document.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml\"/></Types>".utf8)),
            ("_rels/.rels",Data("<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"word/document.xml\"/></Relationships>".utf8)),
            ("word/document.xml",Data("<w:document xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\"><w:body><w:p><w:r><w:t>ORCHID DOCX 314</w:t></w:r></w:p><w:tbl><w:tr><w:tc><w:p><w:r><w:t>Item</w:t></w:r></w:p></w:tc><w:tc><w:p><w:r><w:t>Cost 582</w:t></w:r></w:p></w:tc></w:tr></w:tbl><w:p><w:r><w:t>Ending FALCON</w:t></w:r></w:p></w:body></w:document>".utf8)),
            ("word/header1.xml",Data("<w:hdr xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\"><w:p><w:r><w:t>HEADER COBALT</w:t></w:r></w:p></w:hdr>".utf8))]
        if image {
            let bitmap=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:100,pixelsHigh:100,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:400,bitsPerPixel:32)!
            for y in 0..<100 {for x in 0..<100 {bitmap.setColor(NSColor(deviceRed:1,green:0,blue:0,alpha:1),atX:x,y:y)}}
            entries.append(("word/media/image1.png",try XCTUnwrap(bitmap.representation(using:.png,properties:[:]))))
        }
        entries = entries.map { name,bytes in
            guard name=="word/document.xml" else{return(name,bytes)}
            var xml=String(data:bytes,encoding:.utf8)!
            xml=xml.replacingOccurrences(of:"<w:document ",with:"<w:document xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\" xmlns:wp=\"http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing\" xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\" xmlns:pic=\"http://schemas.openxmlformats.org/drawingml/2006/picture\" ")
            let drawing=image ? "<w:p><w:r><w:drawing><wp:inline><wp:extent cx=\"914400\" cy=\"914400\"/><wp:docPr id=\"1\" name=\"Red square\" descr=\"Red square\"/><a:graphic><a:graphicData uri=\"http://schemas.openxmlformats.org/drawingml/2006/picture\"><pic:pic><pic:nvPicPr><pic:cNvPr id=\"1\" name=\"Red square\"/><pic:cNvPicPr/></pic:nvPicPr><pic:blipFill><a:blip r:embed=\"image1\"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill><pic:spPr><a:xfrm><a:off x=\"0\" y=\"0\"/><a:ext cx=\"914400\" cy=\"914400\"/></a:xfrm><a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom></pic:spPr></pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r></w:p>" : ""
            xml=xml.replacingOccurrences(of:"</w:body>",with:drawing+"<w:sectPr><w:headerReference w:type=\"default\" r:id=\"header1\"/></w:sectPr></w:body>")
            return(name,Data(xml.utf8))
        }
        let relations="<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"header1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/header\" Target=\"header1.xml\"/>"+(image ? "<Relationship Id=\"image1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/image\" Target=\"media/image1.png\"/>" : "")+"</Relationships>"
        entries.append(("word/_rels/document.xml.rels",Data(relations.utf8)))
        return entries
    }
    func root()->URL {URL(fileURLWithPath:"/private/tmp").appendingPathComponent("hud-word-"+UUID().uuidString)}
    func testActualDOCXTextTablesHeaderImagePrivateRestartAndDeflate()throws {
        let folder=root();defer{try? FileManager.default.removeItem(at:folder)}
        let store=WordAttachments(directory:folder)
        for deflate in [false,true] {
            let bytes=zip(try entries(),deflate:deflate)
            let source=folder.appendingPathExtension("docx")
            try bytes.write(to:source);defer{try? FileManager.default.removeItem(at:source)}
            let item=try deflate ? store.importFile(source) : store.importData(name:"fixture.docx",dataBase64:bytes.base64EncodedString())
            let url=try WordAttachments(directory:folder).reference(item)
            XCTAssertEqual(try Data(contentsOf:url),bytes)
            let result=try WordAnalysis.prepare(url:url)
            XCTAssertEqual(result.images.count,1)
            let sheet=try XCTUnwrap(NSBitmapImageRep(data:Data(base64Encoded:result.images[0]["data"] as! String)!))
            XCTAssertLessThanOrEqual(max(sheet.pixelsWide,sheet.pixelsHigh),2000)
            let center=try XCTUnwrap(sheet.colorAt(x:400,y:300)?.usingColorSpace(.deviceRGB))
            XCTAssertGreaterThan(center.redComponent,0.8);XCTAssertLessThan(center.greenComponent,0.2)
            let artifact=url.deletingPathExtension().appendingPathExtension("analysis.txt")
            let text=try String(contentsOf:artifact)
            for expected in ["ORCHID DOCX 314","[Table]","[Row]","[Cell] Item","Cost 582","HEADER COBALT","Ending FALCON"] {XCTAssertTrue(text.contains(expected),expected)}
            XCTAssertTrue(result.summary.contains(encode(url.path)));XCTAssertTrue(result.summary.contains("not full visual understanding"))
            XCTAssertEqual((try FileManager.default.attributesOfItem(atPath:artifact.path)[.posixPermissions] as? NSNumber)?.intValue,0o600)
            XCTAssertEqual((try FileManager.default.attributesOfItem(atPath:folder.path)[.posixPermissions] as? NSNumber)?.intValue,0o700)
            if let path=ProcessInfo.processInfo.environment["HERDR_WORD_FIXTURE_DIR"],deflate {
                let export=URL(fileURLWithPath:path);try FileManager.default.createDirectory(at:export,withIntermediateDirectories:true)
                try "Body: ORCHID DOCX 314; table: Item | Cost 582; ending: Ending FALCON; header: HEADER COBALT; embedded square: red.\n".write(to:export.appendingPathComponent("ground-truth.txt"),atomically:true,encoding:.utf8)
                try bytes.write(to:export.appendingPathComponent("fixture.docx"));try text.write(to:export.appendingPathComponent("analysis.txt"),atomically:true,encoding:.utf8)
                try result.summary.write(to:export.appendingPathComponent("material.txt"),atomically:true,encoding:.utf8)
                try Data(base64Encoded:result.images[0]["data"] as! String)!.write(to:export.appendingPathComponent("sheet.jpg"))
            }
        }
    }
    func testTextOnlyAndSecurityRejections()throws {
        let folder=root();defer{try? FileManager.default.removeItem(at:folder)}
        let store=WordAttachments(directory:folder),base=try entries(image:false)
        let item=try store.importData(name:"text.docx",dataBase64:zip(base).base64EncodedString()),url=try store.reference(item)
        XCTAssertTrue(try WordAnalysis.prepare(url:url).images.isEmpty)
        for extra in [("../escape",Data("x".utf8)),("word/vbaProject.bin",Data("macro".utf8)),("word/evil.xml",Data("<!DOCTYPE x [<!ENTITY a 'BOMB'>]><x>&a;</x>".utf8)),("word/_rels/document.xml.rels",Data("<Relationships><Relationship TargetMode=\"External\" Type=\"image\" Target=\"https://example.com/pixel\"/></Relationships>".utf8))] {
            XCTAssertThrowsError(try WordPackage(data:zip(base+[extra])))
        }
        XCTAssertNoThrow(try WordPackage(data:zip(base+[("word/printerSettings/printerSettings1.bin",Data([0,1,2,3]))])))
        XCTAssertThrowsError(try WordPackage(data:zip(base+[("word/embeddings/oleObject1.bin",Data([0,1,2,3]))])))
        XCTAssertThrowsError(try WordPackage(data:zip(base+[("word/media/payload.bin",Data([0,1,2,3]))])))
        let link=("word/_rels/hyperlink.xml.rels",Data("<Relationships><Relationship TargetMode=\"External\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink\" Target=\"https://example.com/\"/></Relationships>".utf8))
        XCTAssertNoThrow(try WordPackage(data:zip(base+[link])))
        XCTAssertThrowsError(try WordPackage(data:zip(base+[("bomb",Data(repeating:0,count:8*1024*1024+1))])))
        try Data(repeating:0,count:zip(base).count).write(to:url)
        XCTAssertNoThrow(try store.reference(item,verifyContent:false));XCTAssertThrowsError(try store.reference(item))
        var invalid=item;invalid["bytes"]=true;XCTAssertThrowsError(try WordAttachments.validateReference(invalid))
        invalid=item;invalid["name"]="../bad.docx";XCTAssertThrowsError(try WordAttachments.validateReference(invalid))
    }
    func testSymlinkQuotaAndFullTextArtifactGuard()throws {
        let folder=root();defer{try? FileManager.default.removeItem(at:folder)}
        let store=WordAttachments(directory:folder),bytes=zip(try entries(image:false))
        let item=try store.importData(name:"safe.docx",dataBase64:bytes.base64EncodedString()),url=try store.reference(item)
        let link=folder.appendingPathComponent("source.docx");try FileManager.default.createSymbolicLink(at:link,withDestinationURL:url)
        XCTAssertThrowsError(try store.importFile(link));try FileManager.default.removeItem(at:link)
        let target=folder.appendingPathComponent("untouched");try Data("keep".utf8).write(to:target);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:target.path)
        let artifact=url.deletingPathExtension().appendingPathExtension("analysis.txt");try FileManager.default.createSymbolicLink(at:artifact,withDestinationURL:target)
        XCTAssertThrowsError(try WordAnalysis.prepare(url:url));XCTAssertEqual(try String(contentsOf:target),"keep")
        try FileManager.default.removeItem(at:artifact)
        let fill=folder.appendingPathComponent("quota"),fd=open(fill.path,O_WRONLY|O_CREAT|O_EXCL,0o600)
        XCTAssertGreaterThanOrEqual(fd,0);XCTAssertEqual(ftruncate(fd,off_t(WordAttachments.maximumCacheBytes)),0);close(fd)
        XCTAssertThrowsError(try store.importData(name:"new.docx",dataBase64:bytes.base64EncodedString()));XCTAssertNoThrow(try store.reference(item))
    }
}
