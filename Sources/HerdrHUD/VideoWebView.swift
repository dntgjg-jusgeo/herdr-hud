import AppKit
import WebKit

/// Native Finder file URLs are distinct from ordinary pasted path text.
final class VideoWebView: WKWebView {
    var videoFiles: (([URL]) -> Void)?
    static func urls(_ pasteboard:NSPasteboard) -> [URL] {
        let urls=(pasteboard.readObjects(forClasses:[NSURL.self],options:[.urlReadingFileURLsOnly:true]) as? [URL]) ?? []
        return !urls.isEmpty && urls.allSatisfy { $0.isFileURL && ["mp4","md","markdown"].contains($0.pathExtension.lowercased()) } ? urls : []
    }
    func pasteVideos() -> Bool {
        let urls=Self.urls(.general);guard !urls.isEmpty else{return false};videoFiles?(urls);return true
    }
    override func performKeyEquivalent(with event:NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,event.charactersIgnoringModifiers == "v",pasteVideos(){return true}
        return super.performKeyEquivalent(with:event)
    }
    override func draggingEntered(_ sender:NSDraggingInfo) -> NSDragOperation {
        Self.urls(sender.draggingPasteboard).isEmpty ? super.draggingEntered(sender) : .copy
    }
    override func draggingUpdated(_ sender:NSDraggingInfo) -> NSDragOperation {
        Self.urls(sender.draggingPasteboard).isEmpty ? super.draggingUpdated(sender) : .copy
    }
    override func prepareForDragOperation(_ sender:NSDraggingInfo) -> Bool {
        Self.urls(sender.draggingPasteboard).isEmpty ? super.prepareForDragOperation(sender) : true
    }
    override func performDragOperation(_ sender:NSDraggingInfo) -> Bool {
        let urls=Self.urls(sender.draggingPasteboard);guard !urls.isEmpty else{return super.performDragOperation(sender)}
        videoFiles?(urls);return true
    }
}
