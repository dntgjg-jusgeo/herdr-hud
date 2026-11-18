import XCTest
@testable import HerdrHUD

final class ChatAppearanceTests: XCTestCase {
    func testOnlyAppearanceFollowsTheSameKeptPane() {
        func session(_ pid: Int, _ birth: Int, _ provider: String) -> String {
            encode(["core","t5",["pid":pid,"provider":provider,"created_ms":birth,"core":"core","remote":NSNull()] as Row])
        }
        let old = session(99,100,"codex"), new = session(111,100,"codex")
        let key = HCClient.appearanceID(old)
        XCTAssertNotEqual(old,new)
        XCTAssertEqual(key,HCClient.appearanceID(new))
        XCTAssertNotEqual(key,HCClient.appearanceID(session(111,101,"codex")))
        XCTAssertNotEqual(key,HCClient.appearanceID(session(111,100,"claude")))
        XCTAssertEqual(HCClient.appearancePreferences([old:"folder"],selected:nil)[key] as? String,"folder")
        XCTAssertNil(HCClient.appearancePreferences([old:"A",new:"B"],selected:nil)[key])
        XCTAssertEqual(HCClient.appearancePreferences([old:"A",new:"B"],selected:old)[key] as? String,"A")
    }
}
