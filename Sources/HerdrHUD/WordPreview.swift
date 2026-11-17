import AppKit
import Quartz

/// Native read-only preview of the validated original DOCX. The cache resolver
/// must fully verify the reference before opening; no WebView or conversion.
final class WordPreview:NSWindowController {
    private let preview:QLPreviewView
    init(url:URL,name:String) {
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:760,height:800),styleMask:[.titled,.closable,.resizable,.miniaturizable],backing:.buffered,defer:false)
        window.title=name;window.isReleasedWhenClosed=false;window.center()
        preview=QLPreviewView(frame:NSRect(x:0,y:0,width:760,height:800),style:.normal)!
        super.init(window:window)
        preview.autoresizingMask=[.width,.height];preview.autostarts=true
        preview.previewItem=url as NSURL
        window.contentView=preview
    }
    required init?(coder:NSCoder){fatalError("init(coder:) is not supported")}
    func stop(){preview.previewItem=nil;preview.close();close()}
}
