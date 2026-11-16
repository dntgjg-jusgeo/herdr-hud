import AppKit
import XCTest
@testable import HerdrHUD

final class DraftStoreTests: XCTestCase {
    func folder() -> URL { URL(fileURLWithPath:"/private/tmp",isDirectory:true).appendingPathComponent("hud-drafts-tests-"+UUID().uuidString,isDirectory:true) }
    func snapshot(_ text:String = "private draft") -> Row {
        let image = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:4,pixelsHigh:4,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!.representation(using:.png,properties:[:])!
        return ["version":1,"drafts":[["id":"exact-agent-identity","label":"A task","text":text,"images":[["name":"original.png","data":image.base64EncodedString()]],"uncertain":true,"keyUncertain":true]]]
    }
    func testPrivateRoundTripAndExplicitClear() throws {
        let url=folder();defer { try? FileManager.default.removeItem(at:url) }
        let store=DraftStore(directory:url)
        XCTAssertThrowsError(try store.save(snapshot()))
        XCTAssertEqual((try store.load()["drafts"] as? [Row])?.count,0)
        try store.save(snapshot())
        let fresh=DraftStore(directory:url),rows=try XCTUnwrap(try fresh.load()["drafts"] as? [Row])
        XCTAssertEqual(rows[0]["id"] as? String,"exact-agent-identity");XCTAssertEqual(rows[0]["text"] as? String,"private draft")
        XCTAssertEqual(rows[0]["uncertain"] as? Bool,true);XCTAssertEqual(rows[0]["keyUncertain"] as? Bool,true)
        XCTAssertEqual((rows[0]["images"] as? [Row])?[0]["name"] as? String,"original.png")
        let fm=FileManager.default
        XCTAssertEqual((try fm.attributesOfItem(atPath:url.path)[.posixPermissions] as? NSNumber)?.intValue,0o700)
        XCTAssertEqual((try fm.attributesOfItem(atPath:url.appendingPathComponent("snapshot.json").path)[.posixPermissions] as? NSNumber)?.intValue,0o600)
        try fresh.save(["version":1,"drafts":[Row]()]);XCTAssertEqual((try DraftStore(directory:url).load()["drafts"] as? [Row])?.count,0)
    }
    func testCorruptSnapshotRetainedAndNeverOverwritten() throws {
        let url=folder();defer { try? FileManager.default.removeItem(at:url) }
        let store=DraftStore(directory:url);_=try store.load()
        let file=url.appendingPathComponent("snapshot.json"),bad=Data("{broken".utf8)
        try bad.write(to:file)
        XCTAssertThrowsError(try store.load());XCTAssertThrowsError(try store.save(snapshot()))
        XCTAssertEqual(try Data(contentsOf:file),bad)
    }
    func testSymlinkTargetAndStoreAreRefusedWithoutTouchingDestination() throws {
        let url=folder(),outside=folder();defer { try? FileManager.default.removeItem(at:url);try? FileManager.default.removeItem(at:outside) }
        try FileManager.default.createDirectory(at:outside,withIntermediateDirectories:true)
        let external=outside.appendingPathComponent("keep"),data=Data("untouched".utf8);try data.write(to:external)
        let store=DraftStore(directory:url);_=try store.load()
        try FileManager.default.createSymbolicLink(at:url.appendingPathComponent("snapshot.json"),withDestinationURL:external)
        XCTAssertThrowsError(try store.save(snapshot()));XCTAssertThrowsError(try store.load());XCTAssertEqual(try Data(contentsOf:external),data)
        try FileManager.default.removeItem(at:url)
        try FileManager.default.createSymbolicLink(at:url,withDestinationURL:outside)
        XCTAssertThrowsError(try DraftStore(directory:url).load())
        XCTAssertThrowsError(try DraftStore(directory:url.appendingPathComponent("child")).load())
    }
    func testBoundsAndRasterValidationPreserveLastSnapshot() throws {
        let url=folder();defer { try? FileManager.default.removeItem(at:url) }
        let store=DraftStore(directory:url);_=try store.load();try store.save(snapshot("original"))
        XCTAssertThrowsError(try store.save(snapshot(String(repeating:"x",count:60001))))
        var invalid=snapshot(),rows=invalid["drafts"] as! [Row]
        rows[0]["images"]=[["name":"bad.svg","data":Data("<svg/>".utf8).base64EncodedString()]];invalid["drafts"]=rows
        XCTAssertThrowsError(try store.save(invalid))
        XCTAssertEqual((try DraftStore(directory:url).load()["drafts"] as? [Row])?[0]["text"] as? String,"original")
    }
}
