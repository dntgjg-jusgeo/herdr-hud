import AppKit
import PDFKit

/// Uses native PDFKit for every page; no browser renderer or raster-only preview.
/// The caller must resolve and fully verify the private attachment before opening.
final class PDFPreview:NSWindowController {
    private let pdfView=PDFView()
    init(url:URL,name:String) {
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:760,height:800),styleMask:[.titled,.closable,.resizable,.miniaturizable],backing:.buffered,defer:false)
        window.title=name;window.isReleasedWhenClosed=false;window.center()
        super.init(window:window)
        pdfView.displayMode = .singlePageContinuous;pdfView.displayDirection = .vertical
        pdfView.autoScales=true;pdfView.minScaleFactor=0.1;pdfView.maxScaleFactor=8
        pdfView.document=PDFDocument(url:url)
        let minus=NSButton(title:"Zoom out",target:self,action:#selector(zoomOut))
        let plus=NSButton(title:"Zoom in",target:self,action:#selector(zoomIn))
        let fit=NSButton(title:"Fit",target:self,action:#selector(fitPage))
        let controls=NSStackView(views:[minus,plus,fit]);controls.spacing=8
        let content=NSView();window.contentView=content
        for view in [controls,pdfView] {view.translatesAutoresizingMaskIntoConstraints=false;content.addSubview(view)}
        NSLayoutConstraint.activate([
            controls.topAnchor.constraint(equalTo:content.topAnchor,constant:8),controls.leadingAnchor.constraint(equalTo:content.leadingAnchor,constant:12),
            pdfView.topAnchor.constraint(equalTo:controls.bottomAnchor,constant:8),pdfView.leadingAnchor.constraint(equalTo:content.leadingAnchor),
            pdfView.trailingAnchor.constraint(equalTo:content.trailingAnchor),pdfView.bottomAnchor.constraint(equalTo:content.bottomAnchor)
        ])
    }
    required init?(coder:NSCoder){fatalError("init(coder:) is not supported")}
    @objc private func zoomIn(){pdfView.zoomIn(nil)}
    @objc private func zoomOut(){pdfView.zoomOut(nil)}
    @objc private func fitPage(){pdfView.autoScales=true}
    func stop(){pdfView.document=nil;close()}
}
