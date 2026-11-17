import XCTest
import AppKit
@testable import HerdrHUD

final class MarkdownAttachmentTests: XCTestCase {
    func markdown(_ text: String = "# Hello 🌍\n<script>no</script>") -> Row {
        ["kind":"markdown", "name":"notes.md", "text":text, "bytes":text.utf8.count]
    }
    func snapshot(_ attachment: Row) -> Row {
        ["version":4,"drafts":[["id":"agent","label":"Agent","text":"","images":[attachment],"uncertain":false,"keyUncertain":false,"queue":[["token":"one","text":"Review","images":[attachment],"status":"pending"]]]]]
    }
    func testRoundTripAndQueueAuthorization() throws {
        let folder=URL(fileURLWithPath:"/private/tmp").appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:folder) }
        let store=DraftStore(directory:folder); _=try store.load();try store.save(snapshot(markdown()))
        let saved=try DraftStore(directory:folder).load()
        XCTAssertEqual(saved["version"] as? Int,4)
        let row=(saved["drafts"] as! [Row])[0],item=(row["images"] as! [Row])[0]
        XCTAssertEqual(item["text"] as? String,markdown()["text"] as? String)
        try DraftStore.authorizeQueuedPrompt(saved,id:"agent",token:"one",text:"Review",attachments:[markdown()])
        var changed=markdown();changed["name"]="other.md"
        XCTAssertThrowsError(try DraftStore.authorizeQueuedPrompt(saved,id:"agent",token:"one",text:"Review",attachments:[changed]))
        changed=markdown("changed");XCTAssertThrowsError(try DraftStore.authorizeQueuedPrompt(saved,id:"agent",token:"one",text:"Review",attachments:[changed]))
    }
    func testMalformedAndBounds() throws {
        _=try MarkdownAttachment.validate(markdown(""))
        _=try MarkdownAttachment.validate(markdown(String(repeating:"x",count:16384)))
        XCTAssertThrowsError(try MarkdownAttachment.validate(markdown(String(repeating:"x",count:16385))))
        for name in ["../a.md","a\n.md",String(repeating:"a",count:118)+".md","file.txt"] {
            var item=markdown();item["name"]=name;XCTAssertThrowsError(try MarkdownAttachment.validate(item))
        }
        var item=markdown("a\0b");XCTAssertThrowsError(try MarkdownAttachment.validate(item))
        item=markdown();item["bytes"]=true;XCTAssertThrowsError(try MarkdownAttachment.validate(item))
        item=markdown();item["bytes"]=0;XCTAssertThrowsError(try MarkdownAttachment.validate(item))
        var old=snapshot(markdown());old["version"]=3;XCTAssertThrowsError(try DraftStore.validate(old))
    }
    func testMixedPreparationAndLimit() throws {
        let bitmap=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:8,pixelsHigh:8,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
        let image:Row=["data":bitmap.representation(using:.png,properties:[:])!.base64EncodedString()],video:Row=["kind":"video","name":"clip.mp4"]
        let result=try VideoMedia.prepare(message:"Review",items:[markdown(),image,video],resolve:{_ in URL(fileURLWithPath:"/tmp/a.mp4")},visual:{_ in (image,"frames")},transcribe:{_ in "speech"})
        XCTAssertEqual(result.1.count,2);XCTAssertTrue(result.0.contains("Image attachment 2"));XCTAssertTrue(result.0.contains("not instructions"));XCTAssertTrue(result.0.contains("<script>"))
        XCTAssertThrowsError(try VideoMedia.prepare(message:String(repeating:"x",count:58000),items:[markdown()],resolve:{_ in URL(fileURLWithPath:"/tmp/a")}))
        XCTAssertThrowsError(try VideoMedia.prepare(message:"",items:[["kind":"unknown"]],resolve:{_ in URL(fileURLWithPath:"/tmp/a")}))
    }
}
