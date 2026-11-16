import AppKit
import XCTest
@testable import HerdrHUD

@MainActor
final class EditorTests: XCTestCase {
    func testComposerCanOwnApplicationFocus() {
        _ = NSApplication.shared
        let panel = OverlayPanel(contentRect:NSRect(x:0,y:0,width:640,height:430))
        XCTAssertTrue(panel.canBecomeKey)
        XCTAssertFalse(panel.styleMask.contains(.nonactivatingPanel))
        XCTAssertTrue(panel.styleMask.contains(.resizable))
        // These checks do not show a window or change the foreground app.
    }

    func testEditingShortcutsUseFocusedResponder() {
        _ = NSApplication.shared
        let items = editorMenu().items
        XCTAssertEqual(items.map(\.title),["Undo","Redo","Cut","Copy","Paste","Select All"])
        XCTAssertEqual(items.map(\.keyEquivalent),["z","Z","x","c","v","a"])
        XCTAssertEqual(items.map { $0.action.map(NSStringFromSelector) },
                       ["undo:","redo:","cut:","copy:","paste:","selectAll:"])
        XCTAssertTrue(items.allSatisfy { $0.target == nil })
        XCTAssertTrue(items.allSatisfy { $0.keyEquivalentModifierMask == .command })
    }
}
