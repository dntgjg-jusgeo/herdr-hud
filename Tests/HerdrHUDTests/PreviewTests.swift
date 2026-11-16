import AppKit
import XCTest
@testable import HerdrHUD

final class PreviewTests: XCTestCase {
    func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        return root
    }
    func image(_ url: URL) throws {
        let rep = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:12,pixelsHigh:8,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
        try rep.representation(using:.png,properties:[:])!.write(to:url)
    }
    func testGalleryDecodesRasterAndScopesOpaqueTokens() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at:root) }
        let outputs = root.appendingPathComponent("outputs",isDirectory:true)
        try FileManager.default.createDirectory(at:outputs,withIntermediateDirectories:true)
        let file = outputs.appendingPathComponent("screenshot ' < &.png"); try image(file)
        try Data("<svg onload='alert(1)'/>".utf8).write(to:root.appendingPathComponent("fake.png"))
        try Data("<svg/>".utf8).write(to:root.appendingPathComponent("vector.svg"))
        let gallery = PreviewGallery(), result = try gallery.list(agent:"one",directory:root)
        let items = try XCTUnwrap(result["items"] as? [Row]); XCTAssertEqual(items.count,1)
        guard let first = items.first else { return XCTFail("Expected a decoded fixture image") }; let item = first, token = try XCTUnwrap(item["token"] as? String)
        XCTAssertEqual(item["name"] as? String,file.lastPathComponent)
        XCTAssertTrue((item["thumbnail"] as? String ?? "").hasPrefix("data:image/jpeg;base64,"))
        let copy = try gallery.snapshot(agent:"one",token:token)
        XCTAssertEqual(copy.lastPathComponent,file.lastPathComponent)
        XCTAssertEqual(try Data(contentsOf:copy),try Data(contentsOf:file))
        XCTAssertThrowsError(try gallery.snapshot(agent:"two",token:token))
        XCTAssertThrowsError(try gallery.snapshot(agent:"one",token:file.path))
        for _ in 0..<3 { _ = try gallery.list(agent:"two",directory:root) }
        XCTAssertThrowsError(try gallery.snapshot(agent:"one",token:token))
    }
    func testChangedFilesAndSymlinksCannotOpen() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at:root) }
        let file = root.appendingPathComponent("shot.png"); try image(file)
        try FileManager.default.createSymbolicLink(at:root.appendingPathComponent("link.png"),withDestinationURL:file)
        let gallery = PreviewGallery(), result = try gallery.list(agent:"one",directory:root)
        let items = try XCTUnwrap(result["items"] as? [Row]); XCTAssertEqual(items.count,1)
        let token = try XCTUnwrap(items.first?["token"] as? String)
        try Data("changed".utf8).write(to:file)
        XCTAssertThrowsError(try gallery.snapshot(agent:"one",token:token))
        try FileManager.default.removeItem(at:file)
        try FileManager.default.createSymbolicLink(at:file,withDestinationURL:root.appendingPathComponent("other.png"))
        XCTAssertThrowsError(try gallery.snapshot(agent:"one",token:token))
        XCTAssertFalse(PreviewGallery.localDirectory(URL(string:"https://example.com/image.png")!))
    }
    func testCountSizeAndDepthLimits() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at:root) }
        for i in 0..<30 { try image(root.appendingPathComponent("shot-\(i).png")) }
        let nested = root.appendingPathComponent("nested",isDirectory:true)
        try FileManager.default.createDirectory(at:nested,withIntermediateDirectories:true)
        try image(nested.appendingPathComponent("hidden.png"))
        let large = root.appendingPathComponent("large.png")
        FileManager.default.createFile(atPath:large.path,contents:nil)
        let handle = try FileHandle(forWritingTo:large); try handle.truncate(atOffset:UInt64(PreviewGallery.maximumBytes + 1)); try handle.close()
        let result = try PreviewGallery().list(agent:"one",directory:root)
        let items = try XCTUnwrap(result["items"] as? [Row]); XCTAssertEqual(items.count,24)
        XCTAssertFalse(items.contains { ["large.png","hidden.png"].contains($0["name"] as? String ?? "") })
    }
}
