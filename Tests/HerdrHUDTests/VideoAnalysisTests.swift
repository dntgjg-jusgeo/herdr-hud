import XCTest
import AVFoundation
import AppKit
@testable import HerdrHUD

final class VideoAnalysisTests: XCTestCase {
    func testSampleTimesCoverBeginningMiddleAndEndWithoutRequestingEOF() throws {
        let times = try VideoAnalysis.sampleTimes(duration: 6)
        XCTAssertEqual(times.count, 6)
        XCTAssertEqual(times[0], 0)
        XCTAssertEqual(times[3], 3.54, accuracy: 0.00001)
        XCTAssertEqual(times[5], 5.9, accuracy: 0.00001)
        let short = try VideoAnalysis.sampleTimes(duration: 0.001)
        XCTAssertGreaterThan(short[5], 0); XCTAssertLessThan(short[5], 0.001)
        for invalid in [0, -1, Double.infinity, Double.nan, 86401] {
            XCTAssertThrowsError(try VideoAnalysis.sampleTimes(duration: invalid))
        }
    }

    func testChangingVideoProducesOrderedDecodedContactSheet() throws {
        let directory = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("hud-analysis-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("changing.mp4")
        try makeVideo(source)
        let result = try VideoAnalysis.prepare(url: source)
        let bytes = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(result.image["data"] as? String)))
        XCTAssertLessThanOrEqual(bytes.count, ImageAttachment.maximumBytes)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: bytes))
        XCTAssertEqual(bitmap.pixelsWide, VideoAnalysis.sheetWidth)
        XCTAssertEqual(bitmap.pixelsHigh, VideoAnalysis.sheetHeight)
        let colors: [(Double, Double, Double)] = [(1,0,0), (0,1,0), (0,0,1), (1,1,0), (1,0,1), (0,1,1)]
        for (index, expected) in colors.enumerated() {
            let color = try XCTUnwrap(bitmap.colorAt(x: index % 2 * VideoAnalysis.cellWidth + VideoAnalysis.cellWidth / 2,
                                                     y: index / 2 * (VideoAnalysis.frameHeight + VideoAnalysis.labelHeight) + VideoAnalysis.frameHeight / 2)?.usingColorSpace(.sRGB))
            // H.264's YCbCr/color conversion changes saturated RGB values.
            // Distinct high/low channel signatures prove that all six temporal
            // samples survived decoding and retained their exact sheet order.
            for (actual, wanted) in zip([color.redComponent, color.greenComponent, color.blueComponent],
                                        [expected.0, expected.1, expected.2]) {
                if wanted == 1 { XCTAssertGreaterThan(actual, 0.8, "sample \(index) high channel") }
                else { XCTAssertLessThan(actual, 0.35, "sample \(index) low channel") }
            }
        }
        XCTAssertTrue(result.summary.contains("Actual frame times:"))
        XCTAssertTrue(result.summary.contains("Visual samples do not include audio"))
        XCTAssertTrue(result.summary.contains("brief events between samples may be missed"))
        XCTAssertEqual(try ImageAttachment.parse([result.image]).count, 1)
    }

    func testInvalidAndSymlinkInputsAreRejected() throws {
        XCTAssertThrowsError(try VideoAnalysis.prepare(url: URL(string: "https://example.com/a.mp4")!))
        let directory = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("hud-analysis-invalid-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let bad = directory.appendingPathComponent("fake.mp4")
        try Data("this is not a movie".utf8).write(to: bad)
        XCTAssertThrowsError(try VideoAnalysis.prepare(url: bad))
        let link = directory.appendingPathComponent("linked.mp4")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: bad)
        XCTAssertThrowsError(try VideoAnalysis.prepare(url: link))
    }

    private func makeVideo(_ url: URL) throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 64, AVVideoHeightKey: 36,
            AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                                        AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                                        AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2]])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
            sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                                           kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 36])
        writer.add(input); XCTAssertTrue(writer.startWriting()); writer.startSession(atSourceTime: .zero)
        let colors: [(UInt8, UInt8, UInt8)] = [(255,0,0), (0,255,0), (0,0,255), (255,255,0), (255,0,255), (0,255,255)]
        for (index, color) in colors.enumerated() {
            var optional: CVPixelBuffer?
            XCTAssertEqual(CVPixelBufferCreate(nil, 64, 36, kCVPixelFormatType_32ARGB, nil, &optional), kCVReturnSuccess)
            let buffer = try XCTUnwrap(optional)
            CVPixelBufferLockBaseAddress(buffer, [])
            let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRow(buffer)
            for y in 0..<36 { for x in 0..<64 {
                let offset = y * stride + x * 4
                base[offset] = 255; base[offset + 1] = color.0; base[offset + 2] = color.1; base[offset + 3] = color.2
            } }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            let deadline = ProcessInfo.processInfo.systemUptime + 5
            while !input.isReadyForMoreMediaData && ProcessInfo.processInfo.systemUptime < deadline { Thread.sleep(forTimeInterval: 0.01) }
            XCTAssertTrue(input.isReadyForMoreMediaData)
            XCTAssertTrue(adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(index), timescale: 1)))
        }
        writer.endSession(atSourceTime: CMTime(value: 6, timescale: 1)); input.markAsFinished()
        let done = DispatchSemaphore(value: 0); writer.finishWriting { done.signal() }
        XCTAssertEqual(done.wait(timeout: .now() + 8), .success)
        XCTAssertEqual(writer.status, .completed, "\(String(describing: writer.error))")
    }
}
