import XCTest
@testable import HerdrHUD

final class FileLinkTests: XCTestCase {
    func testOnlyReferencedRegularFilesBecomeScopedStableLinks() throws {
        let root=FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let file=root.appendingPathComponent("My notes.md")
        try Data("Notes".utf8).write(to:file)
        let links=FileLinks(),output="[Notes](\(file.path))"
        let rows=links.discover(agent:"A",output:output,directory:root.path)
        XCTAssertEqual(rows.count,1)
        let token=rows[0]["token"] as! String
        XCTAssertEqual(try links.resolve(agent:"A",token:token),file)
        XCTAssertThrowsError(try links.resolve(agent:"B",token:token))
        XCTAssertEqual(links.discover(agent:"A",output:output,directory:root.path)[0]["token"] as? String,token)
        XCTAssertTrue(links.discover(agent:"A",output:"[URL](https://example.com/a.md)",directory:root.path).isEmpty)
        XCTAssertThrowsError(try links.resolve(agent:"A",token:token))
        let alias=root.appendingPathComponent("alias.md")
        try FileManager.default.createSymbolicLink(at:alias,withDestinationURL:file)
        XCTAssertTrue(links.discover(agent:"A",output:"`\(alias.path)`",directory:root.path).isEmpty)
        let executable=root.appendingPathComponent("run.command")
        try Data("echo unsafe".utf8).write(to:executable)
        XCTAssertTrue(links.discover(agent:"A",output:"`\(executable.path)`",directory:root.path).isEmpty)
    }
    func testQuickPromptValidation() throws {
        XCTAssertEqual(try QuickPrompts.validate(QuickPrompts.defaults).count,3)
        XCTAssertThrowsError(try QuickPrompts.validate([["label":"","text":"test"]]))
        XCTAssertThrowsError(try QuickPrompts.validate(Array(repeating:QuickPrompts.defaults[0],count:7)))
    }
}
