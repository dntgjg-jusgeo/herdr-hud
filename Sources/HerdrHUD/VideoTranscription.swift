import Foundation
import AVFoundation
import Darwin

/// Local-only speech recognition. Call from the serial media worker, never the main thread.
/// No downloads, credentials, network providers or shell command construction occur here.
enum VideoTranscription {
    static let maximumDuration: Double = 600
    static let maximumOutputBytes = 64 * 1024
    static let maximumTextCharacters = 24_000
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message + " Your draft has been retained." }
    }
    struct Engine {
        let executable: URL
        let model: URL
        let englishOnly: Bool
    }
    private static let lock = NSLock()

    static func discoverEngine() throws -> Engine {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let executables = ["/opt/homebrew/bin/whisper-cli", "/usr/local/bin/whisper-cli"]
        let roots = [home.appendingPathComponent("Library/Application Support/Herdr HUD/Transcription"),
                     home.appendingPathComponent(".cache/hyperframes/whisper/models"),
                     URL(fileURLWithPath: "/opt/homebrew/share/whisper-cpp/models"),
                     URL(fileURLWithPath: "/usr/local/share/whisper-cpp/models")]
        guard let executable = executables.first(where: { fm.isExecutableFile(atPath: $0) }) else {
            throw Failure(message: "Local speech recognition needs whisper.cpp. Install it with Homebrew: brew install whisper-cpp.")
        }
        for name in ["ggml-base.bin", "ggml-base.en.bin", "ggml-small.bin", "ggml-small.en.bin", "ggml-tiny.bin", "ggml-tiny.en.bin"] {
            for root in roots {
                let model = root.appendingPathComponent(name)
                if let attributes = try? fm.attributesOfItem(atPath: model.path),
                   attributes[.type] as? FileAttributeType == .typeRegular,
                   let size = attributes[.size] as? NSNumber, size.intValue > 1_000_000, size.intValue <= 600_000_000 {
                    return Engine(executable: URL(fileURLWithPath: executable), model: model, englishOnly: name.contains(".en."))
                }
            }
        }
        throw Failure(message: "Local speech recognition needs a Whisper tiny, base or small ggml model. Place its ggml-*.bin file in ~/Library/Application Support/Herdr HUD/Transcription, then retry.")
    }

    static func transcribe(url: URL, cancelled: () -> Bool = { false }) throws -> String {
        // A second caller cannot start another memory-heavy recognizer.
        guard lock.try() else { throw Failure(message: "Another local video transcription is still running. Retry when it finishes.") }
        defer { lock.unlock() }
        guard url.isFileURL, url.pathExtension.lowercased() == "mp4" else { throw Failure(message: "Speech recognition requires a local MP4 attachment.") }
        let asset = AVURLAsset(url: url, options: [AVURLAssetReferenceRestrictionsKey: NSNumber(value: 0xffff)])
        let ready = DispatchSemaphore(value: 0)
        asset.loadValuesAsynchronously(forKeys: ["duration", "tracks"]) { ready.signal() }
        guard ready.wait(timeout: .now() + 8) == .success else { asset.cancelLoading(); throw Failure(message: "Reading the MP4 audio timed out.") }
        var error: NSError?
        guard ["duration", "tracks"].allSatisfy({ asset.statusOfValue(forKey: $0, error: &error) == .loaded }) else { throw Failure(message: "The MP4 audio could not be read.") }
        try validateDuration(CMTimeGetSeconds(asset.duration))
        guard let track = asset.tracks(withMediaType: .audio).first else { return "Audio status: this MP4 has no audio track." }
        guard !cancelled() else { throw Failure(message: "Video transcription was cancelled.") }
        let engine = try discoverEngine()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("herdr-transcription-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let audio = directory.appendingPathComponent("audio.wav")
        try extractAudio(asset: asset, track: track, destination: audio, cancelled: cancelled)
        let output = directory.appendingPathComponent("transcript.txt")
        try run(executable: engine.executable, arguments: arguments(engine: engine, audio: audio), output: output, timeout: 180, cancelled: cancelled)
        let data = try Data(contentsOf: output)
        return try transcript(data, englishOnly: engine.englishOnly)
    }

    static func validateDuration(_ seconds: Double) throws {
        guard seconds.isFinite, seconds > 0, seconds <= maximumDuration else { throw Failure(message: "Speech recognition supports MP4 clips up to 10 minutes. Trim the clip and attach it again.") }
    }
    static func arguments(engine: Engine, audio: URL) -> [String] {
        ["--model", engine.model.path, "--file", audio.path, "--threads", "2", "--processors", "1", "--no-gpu", "--no-prints", "--no-fallback", "--best-of", "1", "--beam-size", "1", "--language", engine.englishOnly ? "en" : "auto"]
    }
    static func transcript(_ data: Data, englishOnly: Bool) throws -> String {
        guard data.count <= maximumOutputBytes, let raw = String(data: data, encoding: .utf8) else { throw Failure(message: "The local transcript exceeded its output limit or was unreadable. Try a shorter clip.") }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count <= maximumTextCharacters else { throw Failure(message: "The local transcript is too long. Trim the clip and attach it again.") }
        if text.isEmpty { return "Audio status: no speech was recognized by the local Whisper model." }
        return "Local automatic speech transcript (may contain errors; " + (englishOnly ? "English model" : "language detected locally") + "):\n" + text
    }

    private static func extractAudio(asset: AVAsset, track: AVAssetTrack, destination: URL, cancelled: () -> Bool) throws {
        let reader = try AVAssetReader(asset: asset)
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw Failure(message: "The MP4 audio format is unsupported.") }
        reader.add(output)
        guard FileManager.default.createFile(atPath: destination.path, contents: Data(repeating: 0, count: 44), attributes: [.posixPermissions: 0o600]) else { throw Failure(message: "Cannot create temporary local audio.") }
        let file = try FileHandle(forWritingTo: destination)
        defer { try? file.close(); reader.cancelReading() }
        try file.seekToEnd()
        guard reader.startReading() else { throw Failure(message: "Cannot decode the MP4 audio.") }
        let deadline = ProcessInfo.processInfo.systemUptime + 30
        var count = 0
        // AVAssetReader can block inside copyNextSampleBuffer; a watchdog cancels decoding too.
        let watchdog = DispatchWorkItem { reader.cancelReading() }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 30, execute: watchdog)
        defer { watchdog.cancel() }
        while let sample = output.copyNextSampleBuffer() {
            guard !cancelled(), ProcessInfo.processInfo.systemUptime < deadline else { throw Failure(message: "Decoding MP4 audio was cancelled or timed out.") }
            guard let block = CMSampleBufferGetDataBuffer(sample) else { throw Failure(message: "Cannot read decoded MP4 audio.") }
            let size = CMBlockBufferGetDataLength(block)
            guard size > 0, size <= 2 * 1024 * 1024, count + size <= 19_200_000 else { throw Failure(message: "Decoded MP4 audio exceeds its limit. Trim the clip.") }
            var data = Data(count: size)
            let status = data.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: size, destination: $0.baseAddress!) }
            guard status == kCMBlockBufferNoErr else { throw Failure(message: "Cannot read decoded MP4 audio.") }
            try file.write(contentsOf: data)
            count += size
        }
        guard reader.status == .completed, count > 0, !cancelled() else { throw Failure(message: "MP4 audio decoding failed, was cancelled or timed out.") }
        var header = Data("RIFF".utf8)
        func append(_ value: UInt32) { var n = value.littleEndian; withUnsafeBytes(of: &n) { header.append(contentsOf: $0) } }
        func append16(_ value: UInt16) { var n = value.littleEndian; withUnsafeBytes(of: &n) { header.append(contentsOf: $0) } }
        append(UInt32(count + 36)); header.append(Data("WAVEfmt ".utf8)); append(16); append16(1); append16(1); append(16000); append(32000); append16(2); append16(16); header.append(Data("data".utf8)); append(UInt32(count))
        try file.seek(toOffset: 0); try file.write(contentsOf: header)
    }

    /// File-backed stdout avoids an unbounded pipe buffer; poll and kill on size/time/cancellation.
    static func run(executable: URL, arguments: [String], output: URL, timeout: Double, cancelled: () -> Bool = { false }) throws {
        guard FileManager.default.createFile(atPath: output.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw Failure(message: "Cannot create a temporary transcript.") }
        let file = try FileHandle(forWritingTo: output)
        defer { try? file.close() }
        let process = Process()
        process.executableURL = executable; process.arguments = arguments
        process.standardInput = FileHandle.nullDevice; process.standardOutput = file; process.standardError = FileHandle.nullDevice
        // Bound math libraries too; do not inherit credentials or dynamic-loader configuration.
        process.environment = ["PATH": "/usr/bin:/bin", "HOME": FileManager.default.homeDirectoryForCurrentUser.path, "OMP_NUM_THREADS": "2", "OPENBLAS_NUM_THREADS": "2", "VECLIB_MAXIMUM_THREADS": "2"]
        do { try process.run() } catch { throw Failure(message: "Cannot start local whisper-cli. Check the Homebrew whisper-cpp installation.") }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var failure: String?
        while process.isRunning {
            let bytes = ((try? FileManager.default.attributesOfItem(atPath: output.path)[.size]) as? NSNumber)?.intValue ?? maximumOutputBytes + 1
            if cancelled() { failure = "Video transcription was cancelled." }
            else if bytes > maximumOutputBytes { failure = "The local transcript exceeded its output limit. Try a shorter clip." }
            else if ProcessInfo.processInfo.systemUptime >= deadline { failure = "Local speech recognition timed out after three minutes. Try a shorter clip." }
            if failure != nil {
                process.terminate()
                let grace = ProcessInfo.processInfo.systemUptime + 0.5
                while process.isRunning && ProcessInfo.processInfo.systemUptime < grace { Thread.sleep(forTimeInterval: 0.02) }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                break
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        process.waitUntilExit()
        if let failure { throw Failure(message: failure) }
        guard process.terminationStatus == 0 else { throw Failure(message: "Local speech recognition failed. Check that the Whisper model is valid, then retry.") }
        let bytes = ((try? FileManager.default.attributesOfItem(atPath: output.path)[.size]) as? NSNumber)?.intValue ?? maximumOutputBytes + 1
        guard bytes <= maximumOutputBytes else { throw Failure(message: "The local transcript exceeded its output limit. Try a shorter clip.") }
    }
}
