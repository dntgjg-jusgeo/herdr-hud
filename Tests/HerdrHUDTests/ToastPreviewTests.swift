import XCTest
import AppKit
@testable import HerdrHUD

final class ToastPreviewTests: XCTestCase {
    func testLongPreviewFitsBodyWithoutCuttingGlyphs() {
        let font=NSFont.systemFont(ofSize:12)
        for input in [String(repeating:"Implemented the card stack. ",count:40),String(repeating:"W",count:500),String(repeating:"截图已完成 ✅ ",count:80)] {
            let output=ToastPreview.fitted(input,font:font,width:282,height:46)
            let measured=(output as NSString).boundingRect(with:NSSize(width:282,height:CGFloat.greatestFiniteMagnitude),options:[.usesLineFragmentOrigin,.usesFontLeading],attributes:[.font:font])
            XCTAssertLessThanOrEqual(measured.height,46)
            XCTAssertTrue(output.hasSuffix("…"))
        }
        XCTAssertEqual(ToastPreview.fitted("Build passed.",font:font,width:282,height:46),"Build passed.")
    }
}
