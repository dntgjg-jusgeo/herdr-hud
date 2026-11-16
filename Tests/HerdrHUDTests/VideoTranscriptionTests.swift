import XCTest
@testable import HerdrHUD

final class VideoTranscriptionTests: XCTestCase {
    func testDurationRejectsInvalidAndLongClipsWithoutTruncation() throws {
        for duration in [0, -1, Double.nan, Double.infinity, 600.01] {
            XCTAssertThrowsError(try VideoTranscription.validateDuration(duration))
        }
        try VideoTranscription.validateDuration(600)
    }
    func testRecognizerArgumentsBoundComputeAndPreserveLiteralPaths() {
        let engine = VideoTranscription.Engine(executable: URL(fileURLWithPath: "/test/whisper-cli"), model: URL(fileURLWithPath: "/test/model $(touch NEVER).bin"), englishOnly: true)
        let audio = URL(fileURLWithPath: "/test/audio with spaces.wav")
        let args = VideoTranscription.arguments(engine: engine, audio: audio)
        XCTAssertEqual(args[1], engine.model.path)
        XCTAssertEqual(args[3], audio.path)
        XCTAssertEqual(Array(args[4...8]), ["--threads", "2", "--processors", "1", "--no-gpu"])
        XCTAssertEqual(args.last, "en")
        XCTAssertFalse(args.contains("--translate"))
    }
    func testTranscriptRetainsTimestampsAndLabelsUncertainRecognition() throws {
        let text = try VideoTranscription.transcript(Data("[00:00:01.000 --> 00:00:02.000] Hello there.\n".utf8), englishOnly: true)
        XCTAssertTrue(text.contains("may contain errors; English model"))
        XCTAssertTrue(text.contains("[00:00:01.000 --> 00:00:02.000] Hello there."))
        XCTAssertTrue(try VideoTranscription.transcript(Data(" \n".utf8), englishOnly: false).contains("no speech was recognized"))
    }
    func testTranscriptRejectsOversizedAndInvalidOutput() {
        XCTAssertThrowsError(try VideoTranscription.transcript(Data(repeating: 65, count: VideoTranscription.maximumOutputBytes + 1), englishOnly: false))
        XCTAssertThrowsError(try VideoTranscription.transcript(Data(repeating: 65, count: VideoTranscription.maximumTextCharacters + 1), englishOnly: false))
        XCTAssertThrowsError(try VideoTranscription.transcript(Data([0xff]), englishOnly: false))
    }
    private func temporaryOutput() throws -> (URL, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return (directory, directory.appendingPathComponent("output.txt"))
    }
    func testProcessUsesLiteralArgumentsAndFileBackedOutput() throws {
        let (directory, output) = try temporaryOutput(); defer { try? FileManager.default.removeItem(at: directory) }
        let literal = "$(touch NEVER) `echo nope` ; untouched"
        try VideoTranscription.run(executable: URL(fileURLWithPath: "/usr/bin/printf"), arguments: ["%s", literal], output: output, timeout: 2)
        XCTAssertEqual(try String(contentsOf: output), literal)
    }
    func testProcessTimeoutAndCancellationTerminateChild() throws {
        let (directory, output) = try temporaryOutput(); defer { try? FileManager.default.removeItem(at: directory) }
        let start = ProcessInfo.processInfo.systemUptime
        XCTAssertThrowsError(try VideoTranscription.run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["10"], output: output, timeout: 0.1))
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 3)
        XCTAssertThrowsError(try VideoTranscription.run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["10"], output: output, timeout: 2, cancelled: { true }))
    }
    func testProcessRejectsExcessOutputEvenOnImmediateExit() throws {
        let (directory, output) = try temporaryOutput(); defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertThrowsError(try VideoTranscription.run(executable: URL(fileURLWithPath: "/usr/bin/printf"), arguments: ["%s", String(repeating: "a", count: VideoTranscription.maximumOutputBytes + 1)], output: output, timeout: 2))
    }
}
