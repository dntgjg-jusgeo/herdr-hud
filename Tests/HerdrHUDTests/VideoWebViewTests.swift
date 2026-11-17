import AppKit
import XCTest
@testable import HerdrHUD

@MainActor final class VideoWebViewTests:XCTestCase {
    func testOnlyActualSupportedFileURLsAreNativePastes() {
        let board=NSPasteboard.withUniqueName();defer{board.releaseGlobally()}
        board.setString("/tmp/example.mp4",forType:.string)
        XCTAssertTrue(VideoWebView.urls(board).isEmpty)
        board.clearContents();board.writeObjects([NSURL(fileURLWithPath:"/tmp/example.mp4")])
        XCTAssertEqual(VideoWebView.urls(board).map(\.lastPathComponent),["example.mp4"])
        board.clearContents();board.writeObjects([NSURL(fileURLWithPath:"/tmp/example.mp4"),NSURL(fileURLWithPath:"/tmp/example.png")])
        XCTAssertEqual(VideoWebView.urls(board).map(\.lastPathComponent),["example.mp4","example.png"],"Mixed supported Finder files use checked native imports")
        board.clearContents();board.writeObjects([NSURL(fileURLWithPath:"/tmp/notes.md"),NSURL(fileURLWithPath:"/tmp/guide.markdown"),NSURL(fileURLWithPath:"/tmp/clip.mp4"),NSURL(fileURLWithPath:"/tmp/guide.pdf"),NSURL(fileURLWithPath:"/tmp/report.docx")])
        XCTAssertEqual(VideoWebView.urls(board).map(\.lastPathComponent),["notes.md","guide.markdown","clip.mp4","guide.pdf","report.docx"])
        board.clearContents();board.setString("/tmp/notes.md",forType:.string)
        XCTAssertTrue(VideoWebView.urls(board).isEmpty,"Pasted ordinary text is not a file attachment")
        board.clearContents();board.writeObjects([NSURL(string:"https://example.com/clip.mp4")!])
        XCTAssertTrue(VideoWebView.urls(board).isEmpty)
    }
}
