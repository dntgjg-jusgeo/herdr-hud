import XCTest
@testable import HerdrHUD

/// Explicit opt-in: runs only against a synthetic clip, never user media or agents.
final class VideoAnalysisSmokeTests: XCTestCase {
    func testSyntheticVideoWithSpokenAudio() throws {
        guard ProcessInfo.processInfo.environment["HUD_VIDEO_SMOKE"] == "1" else {
            throw XCTSkip("Set HUD_VIDEO_SMOKE=1 after creating /private/tmp/hud-video-analysis-fixture.mp4 to exercise the installed local Whisper engine.")
        }
        let fixture = URL(fileURLWithPath: "/private/tmp/hud-video-analysis-fixture.mp4")
        let transcript = try VideoTranscription.transcribe(url: fixture)
        let lower = transcript.lowercased()
        XCTAssertTrue(lower.contains("pineapple"), transcript)
        XCTAssertTrue(lower.contains("seven") || lower.contains("7"), transcript)
        XCTAssertTrue(lower.contains("nine") || lower.contains("9"), transcript)
        XCTAssertTrue(transcript.contains("-->"), "Transcript must retain timed segments")
        let prepared = try VideoAnalysis.prepare(url: fixture)
        let encoded = try XCTUnwrap(prepared.image["data"] as? String)
        let jpeg = try XCTUnwrap(Data(base64Encoded: encoded))
        try jpeg.write(to: URL(fileURLWithPath: "/private/tmp/hud-video-analysis-sheet.jpg"), options: .atomic)
        try (prepared.summary + "\n\n" + transcript).write(to: URL(fileURLWithPath: "/private/tmp/hud-video-analysis-transcript.txt"), atomically: true, encoding: .utf8)
        XCTAssertTrue(prepared.summary.contains("six sampled frames"))
    }
}
