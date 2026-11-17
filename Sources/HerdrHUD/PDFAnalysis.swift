import Foundation
import PDFKit
import Vision
import AppKit
import CoreText
import Darwin

/// All-page local OCR plus one explicitly sampled visual sheet. Runs only on
/// mediaPreparation, before transport and its final session/readiness checks.
enum PDFAnalysis {
    static let maximumTranscriptBytes = 2 * 1024 * 1024
    static let excerptBytes = 12000
    static func samplePages(count:Int)->[Int] {
        if count <= 6 {return Array(0..<count)}
        return (0..<6).map {Int((Double($0)*Double(count-1)/5).rounded())}
    }
    private final class OCRDeadline {
        let lock=NSLock();var fired=false
        func expire(){lock.lock();fired=true;lock.unlock()}
        func expired()->Bool {lock.lock();defer{lock.unlock()};return fired}
    }
    static func recognize(_ image:CGImage)throws->String {
        let request=VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        // Cancellation bounds a slow recognition request without allowing a
        // timed-out result to reach transport. Rendering is checked separately.
        let deadline=OCRDeadline()
        let timeout=DispatchWorkItem {deadline.expire();request.cancel()}
        DispatchQueue.global(qos:.utility).asyncAfter(deadline:.now()+20,execute:timeout)
        defer{timeout.cancel()}
        do {try VNImageRequestHandler(cgImage:image,options:[:]).perform([request])}
        catch {throw HUDError("PDF page OCR failed or timed out (\(error.localizedDescription)). Your draft is retained.")}
        guard !deadline.expired() else{throw HUDError("PDF page OCR timed out. Your draft is retained.")}
        return (request.results ?? []).compactMap{$0.topCandidates(1).first?.string}.joined(separator:"\n")
    }
    static func render(_ page:PDFPage)throws->CGImage {
        guard let reference=page.pageRef else{throw HUDError("PDF page cannot be rendered. Your draft is retained.")}
        let bounds=page.bounds(for:.cropBox)
        guard bounds.width.isFinite,bounds.height.isFinite,bounds.width>0,bounds.height>0,
              bounds.width<=100000,bounds.height<=100000 else{throw HUDError("PDF page dimensions exceed analysis limits.")}
        let scale=min(2000/bounds.width,2000/bounds.height)
        let width=max(1,Int(ceil(bounds.width*scale))),height=max(1,Int(ceil(bounds.height*scale)))
        guard let context=CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,
                                    space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.noneSkipLast.rawValue) else{throw HUDError("Cannot allocate PDF page analysis.")}
        let rect=CGRect(x:0,y:0,width:width,height:height)
        context.setFillColor(CGColor(gray:1,alpha:1));context.fill(rect)
        context.concatenate(reference.getDrawingTransform(.cropBox,rect:rect,rotate:0,preserveAspectRatio:true))
        context.drawPDFPage(reference)
        guard let image=context.makeImage() else{throw HUDError("Cannot render PDF page analysis.")};return image
    }
    static func persist(_ text:String,url:URL)throws->URL {
        let folder=url.deletingLastPathComponent(),output=url.deletingPathExtension().appendingPathExtension("analysis.txt")
        let dir=open(folder.path,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC)
        guard dir>=0 else{throw HUDError("Cannot open private PDF analysis storage.")};defer{close(dir)}
        var info=stat()
        guard fstat(dir,&info)==0,info.st_uid==geteuid(),info.st_mode&0o077==0 else{throw HUDError("PDF analysis requires private storage.")}
        let data=Data(text.utf8)
        // The source PDF cache is bounded; include derived transcripts in its
        // same byte budget. Refuse capacity loss rather than deleting old assets.
        var bytes=0
        for name in try FileManager.default.contentsOfDirectory(atPath:folder.path) {
            var item=stat()
            guard fstatat(dir,name,&item,AT_SYMLINK_NOFOLLOW)==0,item.st_mode&S_IFMT==S_IFREG,item.st_uid==geteuid(),item.st_nlink==1,item.st_mode&0o077==0 else{throw HUDError("PDF analysis storage changed.")}
            if name != output.lastPathComponent {bytes+=Int(item.st_size)}
        }
        guard bytes+data.count<=PDFAttachments.maximumCacheBytes else{throw HUDError("PDF cache is full. Your draft is retained.")}
        let temporary=UUID().uuidString+".analysis.part"
        let fd=openat(dir,temporary,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0o600)
        guard fd>=0 else{throw HUDError("Cannot save full PDF analysis. Your draft is retained.")}
        defer{close(fd);_ = unlinkat(dir,temporary,0)}
        try data.withUnsafeBytes {raw in
            var offset=0
            while offset<raw.count {let n=write(fd,raw.baseAddress!.advanced(by:offset),raw.count-offset);if n<0 && errno==EINTR{continue};guard n>0 else{throw HUDError("Cannot save full PDF analysis.")};offset+=n}
        }
        guard fsync(fd)==0,renameat(dir,temporary,dir,output.lastPathComponent)==0,fsync(dir)==0 else{throw HUDError("Cannot save full PDF analysis.")}
        return output
    }
    static func prepare(url:URL,ocr:(CGImage)throws->String = recognize,saveTranscript:(String,URL)throws->URL = persist,timeLimit:TimeInterval = 180)throws->(image:Row,summary:String) {
        let fd=open(url.path,O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC)
        guard fd>=0 else{throw HUDError("Cannot read PDF for analysis.")};defer{close(fd)}
        var info=stat()
        guard fstat(fd,&info)==0,info.st_mode&S_IFMT==S_IFREG,info.st_size>0,info.st_size<=PDFAttachments.maximumBytes else{throw HUDError("PDF exceeds analysis limits.")}
        var data=Data(),buffer=[UInt8](repeating:0,count:65536)
        while true {let n=read(fd,&buffer,buffer.count);if n<0 && errno==EINTR{continue};guard n>=0,data.count+n<=PDFAttachments.maximumBytes else{throw HUDError("Cannot read PDF for analysis.")};if n==0{break};data.append(contentsOf:buffer.prefix(n))}
        guard let document=PDFDocument(data:data),!document.isEncrypted,!document.isLocked,
              document.pageCount>0,document.pageCount<=PDFAttachments.maximumPages else{throw HUDError("Cannot analyze this PDF.")}
        let selected=samplePages(count:document.pageCount),rows=(selected.count+1)/2,cellWidth=768,cellHeight=1024
        guard let sheet=CGContext(data:nil,width:cellWidth*2,height:cellHeight*rows,bitsPerComponent:8,bytesPerRow:cellWidth*8,
                                  space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.noneSkipLast.rawValue) else{throw HUDError("Cannot allocate PDF contact sheet.")}
        sheet.setFillColor(CGColor(gray:0.08,alpha:1));sheet.fill(CGRect(x:0,y:0,width:cellWidth*2,height:cellHeight*rows))
        var transcript="PDF all-page text analysis. Embedded text and Apple Vision OCR are separate sources and may duplicate each other. OCR is automatic, may miss small/rotated/non-Latin text, and does not interpret diagrams. Every page rendered with longest edge 2000 pixels.\n"
        let deadline=Date().addingTimeInterval(timeLimit)
        for index in 0..<document.pageCount {
            try autoreleasepool {
                guard Date()<deadline,let page=document.page(at:index) else{throw HUDError("PDF analysis exceeded its time limit or a page is unreadable. Your draft is retained.")}
                let image=try render(page),recognized=try ocr(image)
                guard Date()<deadline else{throw HUDError("PDF analysis exceeded its time limit. Your draft is retained.")}
                transcript+="\n[Page \(index+1) of \(document.pageCount)]\nEmbedded text:\n\(page.string ?? "")\nApple Vision OCR (entire rendered page):\n\(recognized.isEmpty ? "[No text recognized; page may be blank or OCR may have missed content.]" : recognized)\n"
                guard transcript.utf8.count<=maximumTranscriptBytes else{throw HUDError("PDF full text exceeds the 2 MB analysis limit. Your draft is retained.")}
                if let slot=selected.firstIndex(of:index) {
                    let x=(slot%2)*cellWidth,bottom=(rows-slot/2-1)*cellHeight
                    let scale=min(Double(cellWidth-24)/Double(image.width),Double(cellHeight-48)/Double(image.height))
                    let w=Double(image.width)*scale,h=Double(image.height)*scale
                    sheet.draw(image,in:CGRect(x:Double(x)+(Double(cellWidth)-w)/2,y:Double(bottom+36)+(Double(cellHeight-48)-h)/2,width:w,height:h))
                    let label=NSAttributedString(string:"Page \(index+1) / \(document.pageCount)",attributes:[NSAttributedString.Key(kCTFontAttributeName as String):CTFontCreateWithName("Menlo" as CFString,20,nil),NSAttributedString.Key(kCTForegroundColorAttributeName as String):CGColor(gray:1,alpha:1)])
                    sheet.textPosition=CGPoint(x:x+12,y:bottom+10);CTLineDraw(CTLineCreateWithAttributedString(label),sheet)
                }
            }
        }
        guard let cg=sheet.makeImage() else{throw HUDError("Cannot render PDF contact sheet.")}
        // Managed OpenCode image input accepts at most 2000 pixels on either
        // axis. Fit every PDF sheet to that shared bound before encoding.
        let factor=min(1,2000/Double(max(cg.width,cg.height)))
        let width=max(1,Int(Double(cg.width)*factor)),height=max(1,Int(Double(cg.height)*factor))
        guard let delivery=CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,
                                     space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.noneSkipLast.rawValue) else{throw HUDError("Cannot resize PDF contact sheet.")}
        delivery.interpolationQuality = .high
        delivery.draw(cg,in:CGRect(x:0,y:0,width:width,height:height))
        guard let bounded=delivery.makeImage() else{throw HUDError("Cannot resize PDF contact sheet.")}
        let bitmap=NSBitmapImageRep(cgImage:bounded)
        var encoded:Data?
        for quality in [0.82,0.65,0.45] {if let candidate=bitmap.representation(using:.jpeg,properties:[.compressionFactor:quality]),candidate.count<=ImageAttachment.maximumBytes {encoded=candidate;break}}
        guard let jpeg=encoded else{throw HUDError("PDF contact sheet exceeds image delivery limits.")}
        let image:Row=["data":jpeg.base64EncodedString()];_ = try ImageAttachment.parse([image])
        let artifact=try saveTranscript(transcript,url)
        var excerpt="",size=0
        for scalar in transcript.unicodeScalars {let s=String(scalar);if size+s.utf8.count>excerptBytes{break};excerpt+=s;size+=s.utf8.count}
        let summary="All \(document.pageCount) pages rendered and OCR processed locally, including pages that already contain embedded text. Contact sheet shows pages \(selected.map{String($0+1)}.joined(separator:", ")) only, ordered left to right, top to bottom; \(selected.count) of \(document.pageCount) pages. This is sampled visual coverage, not complete visual understanding. Inspect the sheet with your image viewing/read tool. Small details, diagrams and unsampled pages require reading/rendering the original PDF. OCR can be inaccurate or incomplete. Full page-marked embedded text + OCR artifact: \(encode(artifact.path)). The original PDF and full text are available to local tools.\nQuoted text excerpt (\(size) of \(transcript.utf8.count) UTF-8 bytes\(size<transcript.utf8.count ? "; truncated, read full artifact" : "; complete")):\n\(encode(excerpt))"
        return(image,summary)
    }
}
