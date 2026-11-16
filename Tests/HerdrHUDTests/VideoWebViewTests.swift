import AppKit
import XCTest
@testable import HerdrHUD

@MainActor final class VideoWebViewTests:XCTestCase {
    func testOnlyActualMP4FileURLsAreNativeVideoPastes() {
        let board=NSPasteboard.withUniqueName();defer{board.releaseGlobally()}
        board.setString("/tmp/example.mp4",forType:.string)
        XCTAssertTrue(VideoWebView.urls(board).isEmpty)
        board.clearContents();board.writeObjects([NSURL(fileURLWithPath:"/tmp/example.mp4")])
        XCTAssertEqual(VideoWebView.urls(board).map(\.lastPathComponent),["example.mp4"])
        board.clearContents();board.writeObjects([NSURL(fileURLWithPath:"/tmp/example.mp4"),NSURL(fileURLWithPath:"/tmp/example.png")])
        XCTAssertTrue(VideoWebView.urls(board).isEmpty,"Mixed drops remain on the web file import route")
        board.clearContents();board.writeObjects([NSURL(string:"https://example.com/clip.mp4")!])
        XCTAssertTrue(VideoWebView.urls(board).isEmpty)
    }
}
