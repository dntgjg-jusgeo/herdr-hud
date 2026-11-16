import XCTest
import AppKit
@testable import HerdrHUD
final class VideoMediaTests:XCTestCase {
    func image() -> Row {let bitmap=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:8,pixelsHigh:8,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!;return ["data":bitmap.representation(using:.png,properties:[:])!.base64EncodedString()]}
    func testVideoGetsActualImageAndTranscriptInOriginalOrder() throws {
        let still=image(),sheet=image(),url=URL(fileURLWithPath:"/private/tmp/fixture.mp4")
        let result=try VideoMedia.prepare(message:"Review",items:[still,["kind":"video","name":"clip.mp4"]],resolve:{_ in url},visual:{_ in (sheet,"Samples at 0, 1, 2 seconds")},transcribe:{_ in "[00:01] spoken fixture"})
        XCTAssertEqual(result.1.count,2);XCTAssertEqual(result.1[0]["data"] as? String,still["data"] as? String)
        XCTAssertTrue(result.0.contains("Image attachment 2"));XCTAssertTrue(result.0.contains("spoken fixture"));XCTAssertTrue(result.0.contains("sampled frames"));XCTAssertEqual(try ImageAttachment.parse(result.1).count,2)
    }
    func testPreparationFailuresNeverReturnPartialPrompt() throws {
        XCTAssertThrowsError(try VideoMedia.prepare(message:"Review",items:[["kind":"video"]],resolve:{_ in URL(fileURLWithPath:"/private/tmp/fixture.mp4")},visual:{_ in (self.image(),"samples")},transcribe:{_ in throw HUDError("missing engine")}))
        XCTAssertThrowsError(try VideoMedia.prepare(message:String(repeating:"x",count:58000),items:[["kind":"video"]],resolve:{_ in URL(fileURLWithPath:"/private/tmp/fixture.mp4")},visual:{_ in (self.image(),"samples")},transcribe:{_ in "speech"}))
    }
}
