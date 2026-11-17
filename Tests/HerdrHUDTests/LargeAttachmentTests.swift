import XCTest
import AppKit
import ImageIO
@testable import HerdrHUD

final class LargeAttachmentTests: XCTestCase {
    func folder() throws -> URL {
        let url = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("hud-large-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    func testMarkdownFullOriginalAndBoundedPreview() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let store = FileAttachments(directory: root.appendingPathComponent("cache"))
        for count in [22 * 1024, FileAttachments.maximumMarkdownBytes] {
            let marker = "\nMARIGOLD-7391\n"
            let text = String(repeating: "x", count: count - marker.utf8.count) + marker
            let file = root.appendingPathComponent("large.md")
            try Data(text.utf8).write(to: file)
            let row = try store.importFile(file), prepared = try store.prepare(row)
            XCTAssertEqual(row["bytes"] as? Int, count)
            XCTAssertNil(row["text"])
            XCTAssertNil(prepared.image)
            XCTAssertEqual(prepared.url.pathExtension, "md")
            XCTAssertEqual(try Data(contentsOf: prepared.url), Data(text.utf8))
            XCTAssertFalse(prepared.summary.contains("MARIGOLD-7391"))
            XCTAssertTrue(prepared.summary.contains(encode(prepared.url.path)))
            XCTAssertLessThan(prepared.summary.utf8.count, 16000)
        }
    }

    func testMarkdownRejectsOversizeInvalidEncodingAndSymlinks() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let store = FileAttachments(directory: root.appendingPathComponent("cache"))
        let file = root.appendingPathComponent("bad.md")
        for data in [Data(repeating: 65, count: FileAttachments.maximumMarkdownBytes + 1), Data([255]), Data([65, 0, 66])] {
            try data.write(to: file)
            XCTAssertThrowsError(try store.importFile(file))
        }
        try Data("valid".utf8).write(to: file)
        let link = root.appendingPathComponent("link.md")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        XCTAssertThrowsError(try store.importFile(link))
        XCTAssertThrowsError(try store.begin(name: "oversize.md", bytes: FileAttachments.maximumMarkdownBytes + 1))
        XCTAssertThrowsError(try store.begin(name: "../escape.md", bytes: 10))
    }

    func testPrivateCopySurvivesOriginalRemovalAndDetectsTampering() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let store = FileAttachments(directory: root.appendingPathComponent("cache"))
        let file = root.appendingPathComponent("notes.md")
        try Data("original".utf8).write(to: file)
        let row = try store.importFile(file), cached = try store.reference(row)
        try FileManager.default.removeItem(at: file)
        XCTAssertEqual(try String(contentsOf: store.reference(row), encoding: .utf8), "original")
        let permissions = try FileManager.default.attributesOfItem(atPath: cached.path)[.posixPermissions] as! NSNumber
        XCTAssertEqual(permissions.intValue & 0o777, 0o600)
        try Data("modified".utf8).write(to: cached)
        XCTAssertThrowsError(try store.reference(row))
    }

    func testChunkedImportChecksOffsetsAndPreservesFilename() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let store = FileAttachments(directory: root.appendingPathComponent("cache"))
        let data = Data(repeating: 65, count: 1024 * 1024 + 7)
        let token = try store.begin(name: "Long notes.markdown", bytes: data.count)
        XCTAssertThrowsError(try store.append(token: token, offset: 1, dataBase64: Data([65]).base64EncodedString()))
        XCTAssertThrowsError(try store.finish(token: token, importer: { _, _ in [:] }))
        try store.append(token: token, offset: 0, dataBase64: data.prefix(1024 * 1024).base64EncodedString())
        try store.append(token: token, offset: 1024 * 1024, dataBase64: data.suffix(7).base64EncodedString())
        let row = try store.finish(token: token, importer: { try store.importFile($0, name: $1) })
        XCTAssertEqual(row["name"] as? String, "Long notes.markdown")
        XCTAssertEqual(try Data(contentsOf: store.reference(row)), data)
        XCTAssertThrowsError(try store.append(token: token, offset: data.count, dataBase64: "QQ=="))
        let canceled = try store.begin(name: "cancel.md", bytes: 8)
        store.cancel(token: canceled)
        XCTAssertThrowsError(try store.append(token: canceled, offset: 0, dataBase64: "QQ=="))
    }

    func testLargeRasterKeepsOriginalAndMakesProviderSizedImage() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1800, pixelsHigh: 1200,
            bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 1800 * 3, bitsPerPixel: 24)!
        var state: UInt32 = 41
        for index in 0..<(bitmap.bytesPerRow * bitmap.pixelsHigh) {
            state ^= state << 13; state ^= state >> 17; state ^= state << 5
            bitmap.bitmapData![index] = UInt8(truncatingIfNeeded: state)
        }
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(data.count, 4 * 1024 * 1024)
        let original = root.appendingPathComponent("large.png"); try data.write(to: original)
        let store = FileAttachments(directory: root.appendingPathComponent("cache"))
        let row = try store.importFile(original), prepared = try store.prepare(row)
        XCTAssertEqual(try Data(contentsOf: prepared.url), data)
        XCTAssertEqual(prepared.url.pathExtension, "png")
        let image = try XCTUnwrap(prepared.image)
        let normalized = try XCTUnwrap(Data(base64Encoded: image["data"] as! String))
        XCTAssertLessThanOrEqual(normalized.count, 4 * 1024 * 1024)
        _ = try ImageAttachment.parse([image])
        let source = try XCTUnwrap(CGImageSourceCreateWithData(normalized as CFData, nil))
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)! as NSDictionary
        XCTAssertLessThanOrEqual(props[kCGImagePropertyPixelWidth] as! Int, 2000)
        XCTAssertLessThanOrEqual(props[kCGImagePropertyPixelHeight] as! Int, 2000)
    }

    func testOptionalExportForIsolatedAgentReadVerification() throws {
        guard let path = ProcessInfo.processInfo.environment["HERDR_LARGE_ATTACHMENT_FIXTURE_DIR"] else { return }
        let root = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let text = "# Full Markdown access test\n\n" + (0..<4000).map { "Line \($0): Synthetic reference content for document access verification.\n" }.joined() + "\n## Final verification\nThe end-of-document marker is MARIGOLD-7391.\n"
        let file = root.appendingPathComponent("large.md"); try Data(text.utf8).write(to: file)
        let store = FileAttachments(directory: root.appendingPathComponent("cache"))
        let row = try store.importFile(file), prepared = try store.prepare(row)
        try Data(prepared.summary.utf8).write(to: root.appendingPathComponent("material.txt"))
        XCTAssertFalse(prepared.summary.contains("MARIGOLD-7391"))
    }

    func testFileReferenceDraftQueueAndLegacyMigration() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("notes.md")
        try Data(repeating: 65, count: 22000).write(to: source)
        let files = FileAttachments(directory: root.appendingPathComponent("files"))
        let ref = try files.importFile(source)
        let legacy: Row = ["kind":"markdown", "name":"old.md", "text":"old", "bytes":3]
        let snapshot: Row = ["version":7, "drafts":[[
            "id":"agent", "label":"Agent", "text":"Review", "images":[legacy, ref],
            "uncertain":false, "keyUncertain":false,
            "queue":[["token":"one", "text":"Review", "images":[ref], "status":"pending"]]
        ]]]
        let store = DraftStore(directory: root.appendingPathComponent("drafts"))
        _ = try store.load(); try store.save(snapshot)
        let saved = try DraftStore(directory: root.appendingPathComponent("drafts")).load()
        XCTAssertEqual(saved["version"] as? Int, 7)
        try DraftStore.authorizeQueuedPrompt(saved, id:"agent", token:"one", text:"Review", attachments:[ref])
        var modified = ref; modified["token"] = UUID().uuidString.lowercased()
        XCTAssertThrowsError(try DraftStore.authorizeQueuedPrompt(saved, id:"agent", token:"one", text:"Review", attachments:[modified]))
        var previous = snapshot; previous["version"] = 6
        XCTAssertThrowsError(try DraftStore.validate(previous))
        let mixed = try VideoMedia.prepare(message:"Review", items:[legacy,ref], resolve:{ _ in source }, file:{ try files.prepare($0) })
        XCTAssertEqual(mixed.1.count, 0)
        XCTAssertTrue(mixed.0.contains("not instructions"))
        XCTAssertTrue(mixed.0.contains(encode(try files.reference(ref).path)))
        XCTAssertLessThan(mixed.0.utf8.count, 58000)
    }

    func testNewVideoLimitPreservesLegacyReferenceAcceptance() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let videos = VideoAttachments(directory: root.appendingPathComponent("videos"))
        let token = try videos.begin(name:"boundary.mp4", bytes:50 * 1024 * 1024)
        videos.cancel(token:token)
        XCTAssertThrowsError(try videos.begin(name:"oversize.mp4", bytes:50 * 1024 * 1024 + 1))
        let bitmap = NSBitmapImageRep(bitmapDataPlanes:nil, pixelsWide:8, pixelsHigh:8,
            bitsPerSample:8, samplesPerPixel:3, hasAlpha:false, isPlanar:false,
            colorSpaceName:.deviceRGB, bytesPerRow:24, bitsPerPixel:24)!
        let poster = "data:image/jpeg;base64," + bitmap.representation(using:.jpeg, properties:[:])!.base64EncodedString()
        let legacy:Row = ["kind":"video", "token":UUID().uuidString.lowercased(), "name":"existing.mp4",
            "bytes":100 * 1024 * 1024, "width":8, "height":8, "duration":1.0, "poster":poster]
        XCTAssertNoThrow(try VideoAttachments.validateReference(legacy))
    }
}
