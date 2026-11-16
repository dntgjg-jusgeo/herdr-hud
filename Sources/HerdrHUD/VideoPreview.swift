import AppKit
import AVKit

final class VideoPreview: NSWindowController, NSWindowDelegate {
    private let player:AVPlayer
    init(url:URL,name:String) {
        let asset=AVURLAsset(url:url,options:[AVURLAssetReferenceRestrictionsKey:NSNumber(value:0xffff)])
        player=AVPlayer(playerItem:AVPlayerItem(asset:asset))
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:720,height:450),styleMask:[.titled,.closable,.resizable,.miniaturizable],backing:.buffered,defer:false)
        window.title=name;window.isReleasedWhenClosed=false;window.center()
        let view=AVPlayerView(frame:window.contentView!.bounds);view.player=player;view.controlsStyle = .inline;view.autoresizingMask=[.width,.height];window.contentView=view
        super.init(window:window);window.delegate=self
    }
    required init?(coder:NSCoder){fatalError("init(coder:) is not supported")}
    func windowWillClose(_ notification:Notification){player.pause();player.replaceCurrentItem(with:nil)}
    func stop(){player.pause();player.replaceCurrentItem(with:nil);close()}
}
