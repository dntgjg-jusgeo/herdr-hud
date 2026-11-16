import Foundation
import AVFoundation
import AppKit
import CoreText
import Darwin

/// Bounded visual evidence for agents without a native movie input. This runs
/// on the attachment work queue, never while importing or previewing a draft.
enum VideoAnalysis {
    static let frameCount = 6
    static let cellWidth = 768
    static let frameHeight = 432
    static let labelHeight = 36
    static let sheetWidth = cellWidth * 2
    static let sheetHeight = (frameHeight + labelHeight) * 3

    static func sampleTimes(duration: Double) throws -> [Double] {
        guard duration.isFinite, duration > 0, duration <= 86400 else {
            throw HUDError("MP4 duration exceeds the analysis limit.")
        }
        // The exact end of an asset has no frame. Keep the last sample inside
        // the playable range, including very short clips.
        let last = duration - min(0.1, duration / 12)
        return (0..<frameCount).map { last * Double($0) / Double(frameCount - 1) }
    }

    private final class Frames {
        let lock = NSLock()
        var values: [(CGImage, Double)?] = Array(repeating: nil, count: frameCount)
        var completed = Set<Int>()
        var closed = false
    }

    static func prepare(url: URL) throws -> (image: Row, summary: String) {
        var file = stat()
        guard url.isFileURL, url.pathExtension.lowercased() == "mp4",
              lstat(url.path, &file) == 0, (file.st_mode & S_IFMT) == S_IFREG,
              file.st_size > 0, file.st_size <= VideoAttachments.maximumBytes else {
            throw HUDError("Use a local MP4 up to 100 MB for visual analysis.")
        }
        let asset = AVURLAsset(url: url, options: [AVURLAssetReferenceRestrictionsKey: NSNumber(value: 0xffff)])
        let loaded = DispatchSemaphore(value: 0)
        asset.loadValuesAsynchronously(forKeys: ["duration", "tracks", "playable"]) { loaded.signal() }
        guard loaded.wait(timeout: .now() + 8) == .success else {
            asset.cancelLoading(); throw HUDError("MP4 analysis metadata timed out. Your draft is retained.")
        }
        var error: NSError?
        guard ["duration", "tracks", "playable"].allSatisfy({ asset.statusOfValue(forKey: $0, error: &error) == .loaded }),
              asset.isPlayable, let track = asset.tracks(withMediaType: .video).first else {
            throw HUDError("MP4 visual analysis requires a playable video track.")
        }
        let size = track.naturalSize.applying(track.preferredTransform)
        guard size.width.isFinite, size.height.isFinite, abs(size.width) >= 1, abs(size.height) >= 1,
              abs(size.width) <= 16384, abs(size.height) <= 16384,
              abs(size.width) * abs(size.height) <= 40_000_000 else {
            throw HUDError("MP4 dimensions exceed the analysis limit.")
        }
        let duration = CMTimeGetSeconds(asset.duration)
        let requested = try sampleTimes(duration: duration).map { CMTime(seconds: $0, preferredTimescale: 600000) }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: cellWidth, height: frameHeight)
        // Exact sampling prevents all six requests resolving to a distant keyframe.
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let frames = Frames(), finished = DispatchSemaphore(value: 0)
        generator.generateCGImagesAsynchronously(forTimes: requested.map { NSValue(time: $0) }) { time, image, actual, result, _ in
            frames.lock.lock(); defer { frames.lock.unlock() }
            guard !frames.closed, let index = requested.firstIndex(where: { CMTimeCompare($0, time) == 0 }),
                  frames.completed.insert(index).inserted else { return }
            let seconds = CMTimeGetSeconds(actual)
            if result == .succeeded, let image, seconds.isFinite, seconds >= 0, seconds <= duration,
               image.width > 0, image.height > 0, image.width <= cellWidth, image.height <= frameHeight {
                frames.values[index] = (image, seconds)
            }
            if frames.completed.count == frameCount { finished.signal() }
        }
        let ready = finished.wait(timeout: .now() + 12) == .success
        frames.lock.lock(); frames.closed = true; let values = frames.values; frames.lock.unlock()
        generator.cancelAllCGImageGeneration()
        guard ready, values.allSatisfy({ $0 != nil }) else {
            throw HUDError("MP4 frame analysis timed out or could not decode all samples. Your draft is retained.")
        }
        let samples = values.map { $0! }
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: sheetWidth, height: sheetHeight, bitsPerComponent: 8,
                                      bytesPerRow: sheetWidth * 4, space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw HUDError("Could not allocate the MP4 analysis contact sheet.")
        }
        context.setFillColor(CGColor(gray: 0.05, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: sheetWidth, height: sheetHeight))
        context.interpolationQuality = .high
        let font = CTFontCreateWithName("Menlo" as CFString, 19, nil)
        for (index, sample) in samples.enumerated() {
            let x = (index % 2) * cellWidth
            let bottom = sheetHeight - (index / 2 + 1) * (frameHeight + labelHeight)
            let scale = min(Double(cellWidth) / Double(sample.0.width), Double(frameHeight) / Double(sample.0.height))
            let width = Double(sample.0.width) * scale, height = Double(sample.0.height) * scale
            context.draw(sample.0, in: CGRect(x: Double(x) + (Double(cellWidth) - width) / 2,
                                             y: Double(bottom + labelHeight) + (Double(frameHeight) - height) / 2,
                                             width: width, height: height))
            let label = String(format: "Frame %d  |  %.3f s", locale: Locale(identifier: "en_US_POSIX"), index + 1, sample.1)
            let text = NSAttributedString(string: label, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font,
                                                                      NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1)])
            context.textPosition = CGPoint(x: x + 12, y: bottom + 10)
            CTLineDraw(CTLineCreateWithAttributedString(text), context)
        }
        guard let sheet = context.makeImage() else { throw HUDError("Could not render the MP4 analysis contact sheet.") }
        let bitmap = NSBitmapImageRep(cgImage: sheet)
        var jpeg: Data?
        for quality in [0.82, 0.65, 0.45] {
            if let data = bitmap.representation(using: .jpeg, properties: [.compressionFactor: quality]), data.count <= ImageAttachment.maximumBytes {
                jpeg = data; break
            }
        }
        guard let jpeg else { throw HUDError("MP4 contact sheet exceeds the image delivery limit.") }
        let row: Row = ["data": jpeg.base64EncodedString()]
        _ = try ImageAttachment.parse([row])
        let times = samples.map { String(format: "%.3f s", locale: Locale(identifier: "en_US_POSIX"), $0.1) }.joined(separator: ", ")
        let summary = String(format: "Visual contact sheet: six sampled frames from a %.3f-second video, ordered left to right, top to bottom. Actual frame times: %@. Analyze these images before answering. This samples visuals rather than full playback; brief events between samples may be missed. Visual samples do not include audio; consult any separately supplied transcript.", locale: Locale(identifier: "en_US_POSIX"), duration, times)
        return (row, summary)
    }
}
