import XCTest
import AppKit
import AVFoundation
import Darwin
@testable import HerdrHUD

final class VideoAttachmentsTests:XCTestCase {
    func folder()->URL{URL(fileURLWithPath:"/private/tmp",isDirectory:true).appendingPathComponent("hud-video-tests-"+UUID().uuidString,isDirectory:true)}
    func metadata()->Row {
        let bitmap=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:4,pixelsHigh:4,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
        return ["poster":"data:image/jpeg;base64,"+bitmap.representation(using:.jpeg,properties:[:])!.base64EncodedString(),"duration":1.0,"width":32,"height":32]
    }
    var bytes:Data {Data([0,0,0,24])+Data("ftypisom".utf8)+Data(repeating:0,count:12)}
    func completed(_ store:VideoAttachments)throws->Row {
        let token=try store.begin(name:"a clip.mp4",bytes:bytes.count)
        try store.append(token:token,offset:0,dataBase64:bytes.base64EncodedString());return try store.finish(token:token)
    }
    func testChunkOffsetsFinalizePrivateCopyAndRestartReference()throws {
        let root=folder();defer{try? FileManager.default.removeItem(at:root)}
        let store=VideoAttachments(directory:root,inspect:{_ in self.metadata()})
        let token=try store.begin(name:"a clip.mp4",bytes:bytes.count)
        XCTAssertThrowsError(try store.append(token:token,offset:1,dataBase64:bytes.base64EncodedString()))
        try store.append(token:token,offset:0,dataBase64:bytes.prefix(8).base64EncodedString())
        XCTAssertThrowsError(try store.finish(token:token))
        try store.append(token:token,offset:8,dataBase64:bytes.dropFirst(8).base64EncodedString())
        let row=try store.finish(token:token),url=try VideoAttachments(directory:root).reference(row)
        XCTAssertEqual(try Data(contentsOf:url),bytes)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath:url.path)[.posixPermissions] as? NSNumber)?.intValue,0o600)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath:root.path)[.posixPermissions] as? NSNumber)?.intValue,0o700)
        store.cancel(token:token);XCTAssertTrue(FileManager.default.fileExists(atPath:url.path))
        try Data(repeating:1,count:bytes.count).write(to:url)
        XCTAssertThrowsError(try store.reference(row))
    }
    func testRefusedNamesLimitsAndNativeSourceSymlinks()throws {
        let root=folder(),outside=folder();defer{try? FileManager.default.removeItem(at:root);try? FileManager.default.removeItem(at:outside)}
        let store=VideoAttachments(directory:root,inspect:{_ in self.metadata()})
        for name in ["../x.mp4","x.mov","x\n.mp4"]{XCTAssertThrowsError(try store.begin(name:name,bytes:20))}
        XCTAssertThrowsError(try store.begin(name:"x.mp4",bytes:VideoAttachments.maximumBytes+1))
        try FileManager.default.createDirectory(at:outside,withIntermediateDirectories:true)
        let source=outside.appendingPathComponent("source.mp4"),link=outside.appendingPathComponent("link.mp4")
        try bytes.write(to:source);try FileManager.default.createSymbolicLink(at:link,withDestinationURL:source)
        XCTAssertThrowsError(try store.importFile(link))
        XCTAssertEqual(try Data(contentsOf:source),bytes)
        let cacheLink=outside.appendingPathComponent("cache")
        try FileManager.default.createSymbolicLink(at:cacheLink,withDestinationURL:root)
        XCTAssertThrowsError(try VideoAttachments(directory:cacheLink).begin(name:"clip.mp4",bytes:24))
    }
    func testReservationCapAndCancellationOnlyRemoveUnfinishedImports()throws {
        let root=folder();defer{try? FileManager.default.removeItem(at:root)}
        let store=VideoAttachments(directory:root,inspect:{_ in self.metadata()})
        var tokens:[String]=[]
        for _ in 0..<3{tokens.append(try store.begin(name:"large.mp4",bytes:VideoAttachments.maximumImportBytes))}
        XCTAssertThrowsError(try store.begin(name:"fourth.mp4",bytes:24))
        for token in tokens{store.cancel(token:token)}
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath:root.path).isEmpty)
        let row=try completed(store),url=try store.reference(row)
        var wrong=row;wrong["bytes"]=true;XCTAssertThrowsError(try VideoAttachments.validateReference(wrong))
        wrong=row;wrong["token"]="../../outside";XCTAssertThrowsError(try store.reference(wrong))
        try FileManager.default.removeItem(at:url)
        try FileManager.default.createSymbolicLink(at:url,withDestinationURL:URL(fileURLWithPath:"/etc/hosts"))
        XCTAssertThrowsError(try store.reference(row))
    }
    func testStalePartialCleanupKeepsFinalFilesAndLongNamesAreBounded()throws {
        let root=folder();defer{try? FileManager.default.removeItem(at:root)}
        let store=VideoAttachments(directory:root,inspect:{_ in self.metadata()})
        let token=try store.begin(name:String(repeating:"🙂",count:100)+".mp4",bytes:bytes.count)
        try store.append(token:token,offset:0,dataBase64:bytes.base64EncodedString())
        let row=try store.finish(token:token);XCTAssertLessThanOrEqual((row["name"] as! String).utf16.count,120)
        let stale=root.appendingPathComponent(UUID().uuidString.lowercased()+".part.mp4")
        XCTAssertTrue(FileManager.default.createFile(atPath:stale.path,contents:bytes,attributes:[.posixPermissions:0o600]))
        try FileManager.default.setAttributes([.modificationDate:Date(timeIntervalSinceNow:-7200)],ofItemAtPath:stale.path)
        _=VideoAttachments(directory:root,inspect:{_ in self.metadata()})
        XCTAssertFalse(FileManager.default.fileExists(atPath:stale.path));XCTAssertNoThrow(try store.reference(row))
        let fill=root.appendingPathComponent("unreferenced.mp4"),fd=open(fill.path,O_WRONLY|O_CREAT|O_EXCL,0o600)
        XCTAssertGreaterThanOrEqual(fd,0);XCTAssertEqual(ftruncate(fd,off_t(470*1024*1024)),0);close(fd)
        XCTAssertThrowsError(try store.begin(name:"over-quota.mp4",bytes:VideoAttachments.maximumImportBytes))
    }
    func testFakeMP4ContainerIsRejectedByNativeVideoValidation()throws {
        let root=folder();defer{try? FileManager.default.removeItem(at:root)}
        let store=VideoAttachments(directory:root),token=try store.begin(name:"fake.mp4",bytes:bytes.count)
        try store.append(token:token,offset:0,dataBase64:bytes.base64EncodedString())
        XCTAssertThrowsError(try store.finish(token:token));store.cancel(token:token)
    }
    func testActualMP4ImportPosterAndDurableReference()throws {
        let root=folder();defer{try? FileManager.default.removeItem(at:root)}
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let source=root.appendingPathComponent("source.mp4"),writer=try AVAssetWriter(outputURL:source,fileType:.mp4)
        let input=AVAssetWriterInput(mediaType:.video,outputSettings:[AVVideoCodecKey:AVVideoCodecType.h264,AVVideoWidthKey:32,AVVideoHeightKey:32])
        let adaptor=AVAssetWriterInputPixelBufferAdaptor(assetWriterInput:input,sourcePixelBufferAttributes:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32ARGB,kCVPixelBufferWidthKey as String:32,kCVPixelBufferHeightKey as String:32])
        writer.add(input);XCTAssertTrue(writer.startWriting());writer.startSession(atSourceTime:.zero)
        var pixel:CVPixelBuffer?;XCTAssertEqual(CVPixelBufferCreate(nil,32,32,kCVPixelFormatType_32ARGB,nil,&pixel),kCVReturnSuccess)
        let buffer=try XCTUnwrap(pixel);CVPixelBufferLockBaseAddress(buffer,[]);memset(CVPixelBufferGetBaseAddress(buffer),0,CVPixelBufferGetDataSize(buffer));CVPixelBufferUnlockBaseAddress(buffer,[])
        let end=ProcessInfo.processInfo.systemUptime+5
        while !input.isReadyForMoreMediaData && ProcessInfo.processInfo.systemUptime<end{Thread.sleep(forTimeInterval:0.01)}
        XCTAssertTrue(adaptor.append(buffer,withPresentationTime:.zero))
        while !input.isReadyForMoreMediaData && ProcessInfo.processInfo.systemUptime<end{Thread.sleep(forTimeInterval:0.01)}
        XCTAssertTrue(adaptor.append(buffer,withPresentationTime:CMTime(value:1,timescale:1)))
        input.markAsFinished();let done=DispatchSemaphore(value:0);writer.finishWriting{done.signal()}
        XCTAssertEqual(done.wait(timeout:.now()+8),.success);XCTAssertEqual(writer.status,.completed)
        let cache=root.appendingPathComponent("cache"),store=VideoAttachments(directory:cache),row=try store.importFile(source)
        XCTAssertEqual(row["kind"] as? String,"video");XCTAssertGreaterThan(row["duration"] as? Double ?? 0,0)
        XCTAssertTrue((row["poster"] as? String)?.hasPrefix("data:image/jpeg;base64,") == true)
        XCTAssertEqual(try Data(contentsOf:VideoAttachments(directory:cache).reference(row)),try Data(contentsOf:source))
    }
}
