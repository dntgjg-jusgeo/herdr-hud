import AppKit
import WebKit
import Carbon
import ServiceManagement
import UniformTypeIdentifiers

final class OverlayPanel: NSPanel {
    init(contentRect: NSRect) {
        // The composer must own application focus so dictation/paste tools target
        // its WebKit editor. Only the passive H button and alerts are nonactivating.
        super.init(contentRect:contentRect,styleMask:[.borderless,.resizable],backing:.buffered,defer:false)
    }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

func editorMenu() -> NSMenu {
    let menu = NSMenu(title:"Edit")
    for (title, action, key) in [
        ("Undo", "undo:", "z"), ("Redo", "redo:", "Z"),
        ("Cut", "cut:", "x"), ("Copy", "copy:", "c"),
        ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")
    ] {
        let item = NSMenuItem(title:title,action:NSSelectorFromString(action),keyEquivalent:key)
        // nil target routes through the focused WKWebView's responder chain.
        item.target = nil
        menu.addItem(item)
    }
    return menu
}
final class BubbleView: NSView {
    weak var app: HUDApp?
    var start = NSPoint.zero, origin = NSPoint.zero, dragged = false
    var count = 0 { didSet { needsDisplay = true } }
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedRed:0.09, green:0.10, blue:0.13, alpha:0.97).setFill()
        let circle = NSBezierPath(ovalIn: bounds.insetBy(dx:3, dy:3)); circle.fill()
        NSColor(calibratedRed:0.91, green:0.72, blue:0.36, alpha:1).setStroke(); circle.lineWidth = 2; circle.stroke()
        let attrs: [NSAttributedString.Key:Any] = [.font:NSFont.systemFont(ofSize:28, weight:.bold), .foregroundColor:NSColor(calibratedRed:0.97,green:0.79,blue:0.43,alpha:1)]
        ("H" as NSString).draw(at:NSPoint(x:20,y:16), withAttributes:attrs)
        if count > 0 {
            NSColor.systemGreen.setFill(); NSBezierPath(ovalIn:NSRect(x:43,y:43,width:17,height:17)).fill()
            (String(min(count,9)) as NSString).draw(at:NSPoint(x:48,y:45),withAttributes:[.font:NSFont.systemFont(ofSize:10,weight:.bold),.foregroundColor:NSColor.black])
        }
    }
    override func mouseDown(with event: NSEvent) { start = NSEvent.mouseLocation; origin = window?.frame.origin ?? .zero; dragged = false }
    override func mouseDragged(with event: NSEvent) {
        let point = NSEvent.mouseLocation
        if hypot(point.x-start.x,point.y-start.y) > 4 { dragged = true }
        guard dragged else { return }
        window?.setFrameOrigin(NSPoint(x:origin.x+point.x-start.x,y:origin.y+point.y-start.y))
        app?.positionPanel()
    }
    override func mouseUp(with event: NSEvent) { if dragged { app?.savePosition() } else { app?.togglePanel() } }
    override func rightMouseDown(with event: NSEvent) { if let menu = app?.status.menu { NSMenu.popUpContextMenu(menu,with:event,for:self) } }
}
final class HUDApp: NSObject, NSApplicationDelegate, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
    let client = HerdrClient(), shepherdr = ShepherdrClient(), work = DispatchQueue(label:"herdr-hud.transport",qos:.userInitiated)
    let defaults = UserDefaults.standard
    let previews = PreviewGallery()
    let fileLinks = FileLinks(), draftStore = DraftStore()
    let orcaModels = OrcaModels(), orcaCatalogWork = DispatchQueue(label:"herdr-hud.orca-catalog",qos:.userInitiated)
    let fileStore=FileAttachments(),videoStore=VideoAttachments(), videoWork=DispatchQueue(label:"herdr-hud.video",qos:.userInitiated)
    let mediaPreparation=DispatchQueue(label:"herdr-hud.media-preparation",qos:.userInitiated)
    let pdfStore=PDFAttachments() // videoWork serializes all attachment cache access
    var pdfPreview:PDFPreview?
    let wordStore=WordAttachments() // videoWork owns cache operations
    var wordPreview:WordPreview?
    var videoPreview:VideoPreview?
    var videoOffers:[String:([URL],String,Date)]=[:]
    var fileImports:[String:String]=[:] // videoWork only
    var videoImports:[String:String]=[:] // videoWork only: upload token -> exact agent ID
    var orcaLaunching = false
    var orcaUncertain = Set<String>() // work queue only; survives adapter recreation
    lazy var orcaLauncher = OrcaSessionLauncher(client:client.hc,opencode:NSHomeDirectory()+"/.opencode/bin/opencode",onTerminalCreated:{ address in
        _ = try? ProcessRunner(timeout:5).run(Invocation(executable:NSHomeDirectory()+"/.local/bin/herdr-app",arguments:["do","terminal.keep","--terminal",address],mutation:true))
    })
    // Access only on work queue. A durable queue item is attempted once per HUD run.
    var queuedPromptClaims = Set<String>()
    lazy var codexLauncher = CodexSessionLauncher(client:client.hc,codex:NSHomeDirectory()+"/.local/bin/codex",onTerminalCreated:{ [weak self] address in
        guard let self=self else { return }
        do {
            _ = try ProcessRunner(timeout:5).run(Invocation(executable:NSHomeDirectory()+"/.local/bin/herdr-app",arguments:["do","terminal.keep","--terminal",address],mutation:true))
            DispatchQueue.main.async { self.emit("newCodexProgress",["message":"The new Codex terminal is open in Herdr. Complete any startup prompt there."]) }
        } catch {
            DispatchQueue.main.async { self.emit("newCodexProgress",["message":"New terminal "+address+" is running. Open it in Herdr to complete startup."]) }
        }
    })
    var codexApprovals: [String:CodexApprovals] = [:], codexApprovalStates: [String:Row] = [:], codexApprovalEpochs: [String:UUID] = [:]
    var codexSteerUncertain=Set<String>()
    var codexApprovalBindings: [String:String] = [:], codexApprovalInvalid=Set<String>()
    var launchingCodex = false
    let draftWork = DispatchQueue(label:"herdr-hud.drafts",qos:.userInitiated)
    let previewWork = DispatchQueue(label:"herdr-hud.previews",qos:.userInitiated)
    var bubble: NSPanel!, panel: OverlayPanel!, bubbleView: BubbleView!, web: WKWebView!, status: NSStatusItem!
    var timer: Timer?, hotkeys: [EventHotKeyRef] = [], handler: EventHandlerRef?
    var visible = true, panelOpen = false, ready = false, polling = false
    var lastSnapshot: Row = [:], readBusy = false, selected = ""
    var promptIDs = Set<String>(), hotkeyWarning = ""
    var toast: NSPanel?, toastTimer: Timer?, toastHover = false
    var previousApplication: NSRunningApplication?
    var shortcuts: [NSMenuItem] = []
    static let channel = Notification.Name("org.herdr.community.hud.control")
    var support: URL { FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("Herdr HUD") }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        try? FileManager.default.createDirectory(at:support,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        visible = defaults.object(forKey:"visible") == nil || defaults.bool(forKey:"visible")
        panel = OverlayPanel(contentRect:NSRect(x:100,y:100,width:940,height:650))
        configure(panel); panel.title = "Herdr HUD Agents"; panel.minSize = NSSize(width:640,height:430)
        let config = WKWebViewConfiguration()
        config.userContentController.add(self,name:"hud")
        config.websiteDataStore = .nonPersistent()
        let videoWeb=VideoWebView(frame:panel.contentView!.bounds,configuration:config)
        videoWeb.videoFiles={ [weak self] urls in self?.offerVideos(urls) };web=videoWeb
        web.autoresizingMask = [.width,.height]; web.navigationDelegate = self; web.uiDelegate = self
        web.setValue(false,forKey:"drawsBackground")
        panel.contentView = web
        web.loadFileURL(HUDResources.root.appendingPathComponent("index.html"),allowingReadAccessTo:HUDResources.root)
        bubble = NSPanel(contentRect:NSRect(x:32,y:180,width:64,height:64),styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
        configure(bubble); bubble.title = "Herdr HUD H Button"; bubble.level = NSWindow.Level(rawValue:panel.level.rawValue+1)
        bubbleView = BubbleView(frame:NSRect(x:0,y:0,width:64,height:64)); bubbleView.app = self
        bubbleView.setAccessibilityRole(.button); bubbleView.setAccessibilityLabel("Herdr HUD. Click to open agents; drag to move.")
        bubble.contentView = bubbleView
        restorePosition()
        status = NSStatusBar.system.statusItem(withLength:NSStatusItem.variableLength)
        status.button?.title = "H"; status.button?.toolTip = "Herdr HUD"
        buildMenu(); registerHotkeys()
        DistributedNotificationCenter.default().addObserver(self,selector:#selector(control(_:)),name:Self.channel,object:nil)
        NSWorkspace.shared.notificationCenter.addObserver(self,selector:#selector(spaceChanged),name:NSWorkspace.activeSpaceDidChangeNotification,object:nil)
        NotificationCenter.default.addObserver(self,selector:#selector(screensChanged),name:NSApplication.didChangeScreenParametersNotification,object:nil)
        NSEvent.addLocalMonitorForEvents(matching:.keyDown) { [weak self] event in
            guard let self = self else { return event }
            if event.keyCode == 53 && self.panelOpen {
                self.web.evaluateJavaScript("window.handleEscape()") { [weak self] _, error in
                    if error != nil { self?.closePanel() }
                }
                return nil
            }
            return event
        }
        if visible { bubble.orderFrontRegardless() }
        timer = Timer.scheduledTimer(withTimeInterval:3,repeats:true) { [weak self] _ in self?.refresh() }
        refresh(); diagnostics()
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard ready else { return .terminateNow }
        web.callAsyncJavaScript("return await window.flushDraftsForQuit()",arguments:[:],in:nil,in:.page) { result in
            switch result {
            case .success: sender.reply(toApplicationShouldTerminate:true)
            case .failure: self.emit("notice",["message":"Could not save your drafts. Keep HUD open and copy your draft before quitting."]); self.openPanel(); sender.reply(toApplicationShouldTerminate:false)
            }
        }
        return .terminateLater
    }
    func configure(_ window: NSPanel) {
        window.isOpaque = false; window.backgroundColor = .clear; window.hasShadow = true
        window.level = .statusBar; window.hidesOnDeactivate = false; window.isFloatingPanel = true
        window.becomesKeyOnlyIfNeeded = false; window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces,.fullScreenAuxiliary,.ignoresCycle]
        if #available(macOS 13.0, *) { window.collectionBehavior.insert(.canJoinAllApplications) }
    }
    func menuItem(_ title: String, _ action: Selector) -> NSMenuItem { let item = NSMenuItem(title:title,action:action,keyEquivalent:""); item.target = self; return item }
    func buildMenu() {
        let main = NSMenu()
        let application = NSMenuItem(title:"Herdr HUD",action:nil,keyEquivalent:"")
        let applicationMenu = NSMenu(title:"Herdr HUD")
        let closeVideoItem = menuItem("Close Attachment Preview",#selector(closeVideoPreview))
        closeVideoItem.keyEquivalent = "w"; applicationMenu.addItem(closeVideoItem)
        let quitItem = menuItem("Quit Herdr HUD",#selector(quit))
        quitItem.keyEquivalent = "q"; applicationMenu.addItem(quitItem)
        application.submenu = applicationMenu; main.addItem(application)
        let edit = NSMenuItem(title:"Edit",action:nil,keyEquivalent:"")
        edit.submenu = editorMenu()
        if let paste=edit.submenu?.items.first(where:{$0.title == "Paste"}) {paste.action=#selector(pasteWithVideos);paste.target=self}
        main.addItem(edit)
        NSApp.mainMenu = main
        let menu = NSMenu()
        menu.addItem(menuItem("Open / close agents",#selector(togglePanel)))
        menu.addItem(menuItem("Show / hide H button",#selector(toggleVisibility)))
        menu.addItem(.separator())
        let root = NSMenuItem(title:"Keyboard shortcuts",action:nil,keyEquivalent:""), submenu = NSMenu()
        for (index,title) in ["⌘⌥H panel · ⌘⌥⇧H hide", "⌃⌥H panel · ⌃⌥⇧H hide", "Shortcuts off"].enumerated() {
            let item = menuItem(title,#selector(changeShortcut(_:))); item.tag = index; shortcuts.append(item); submenu.addItem(item)
        }
        root.submenu = submenu; menu.addItem(root)
        let login = menuItem("Launch at login",#selector(toggleLogin(_:))); login.state = SMAppService.mainApp.status == .enabled ? .on : .off; menu.addItem(login)
        menu.addItem(menuItem("Refresh agents",#selector(refresh)))
        menu.addItem(menuItem("About Herdr HUD",#selector(about)))
        menu.addItem(.separator()); menu.addItem(menuItem("Quit Herdr HUD",#selector(quit)))
        status.menu = menu
    }
    @objc func changeShortcut(_ item: NSMenuItem) { defaults.set(item.tag,forKey:"shortcutMode"); registerHotkeys() }
    func registerHotkeys() {
        for key in hotkeys { UnregisterEventHotKey(key) }; hotkeys = []
        if handler == nil {
            var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, event, pointer in
                guard let event = event, let pointer = pointer else { return noErr }
                var id = EventHotKeyID()
                GetEventParameter(event,EventParamName(kEventParamDirectObject),EventParamType(typeEventHotKeyID),nil,MemoryLayout<EventHotKeyID>.size,nil,&id)
                let app = Unmanaged<HUDApp>.fromOpaque(pointer).takeUnretainedValue()
                if id.id == 1 { app.togglePanel() } else { app.toggleVisibility() }
                return noErr
            },1,&type,Unmanaged.passUnretained(self).toOpaque(),&handler)
        }
        let mode = defaults.integer(forKey:"shortcutMode")
        for item in shortcuts { item.state = item.tag == mode ? .on : .off }
        guard mode != 2 else { hotkeyWarning = ""; return }
        let modifiers = UInt32(optionKey | (mode == 0 ? cmdKey : controlKey))
        hotkeyWarning = ""
        for id in 1...2 {
            var ref: EventHotKeyRef?
            let result = RegisterEventHotKey(UInt32(kVK_ANSI_H),modifiers | (id == 2 ? UInt32(shiftKey) : 0),EventHotKeyID(signature:0x48484431,id:UInt32(id)),GetApplicationEventTarget(),0,&ref)
            if result == noErr, let ref = ref { hotkeys.append(ref) } else { hotkeyWarning = "Shortcut already in use. Choose another combination in the H menu." }
        }
        if !hotkeyWarning.isEmpty { emit("notice",["message":hotkeyWarning]) }
    }
    @objc func toggleLogin(_ item: NSMenuItem) {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() } else { try SMAppService.mainApp.register() }
            item.state = SMAppService.mainApp.status == .enabled ? .on : .off
        } catch { emit("notice",["message":"Login startup could not be enabled: " + error.localizedDescription]); openPanel() }
    }
    @objc func about() { openPanel(); emit("notice",["message":"Herdr HUD · Mac preview 0.1.0 · MIT · Community project, not affiliated with Herdr or Basecamp. Configure machines in Herdr; they appear here automatically."]) }
    @objc func quit() { NSApp.terminate(nil) }
    @objc func toggleVisibility() {
        visible.toggle(); defaults.set(visible,forKey:"visible")
        if visible { bubble.orderFrontRegardless(); refresh() } else { closePanel(); bubble.orderOut(nil); hideToast(); emit("resetBaseline",[:]) }
        diagnostics()
    }
    @objc func togglePanel() { if panelOpen { closePanel() } else { openPanel() } }
    func openPanel() {
        if !panelOpen, let frontmost = NSWorkspace.shared.frontmostApplication,
           frontmost.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previousApplication = frontmost
        }
        visible = true; defaults.set(true,forKey:"visible"); panelOpen = true
        positionPanel(); bubble.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps:true); panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(web); hideToast(); emit("visibility",["open":true]); refresh(); diagnostics()
    }
    func closePanel() {
        let restoreFocus = panelOpen && NSApp.isActive
        panelOpen = false; panel.orderOut(nil); emit("visibility",["open":false])
        if restoreFocus { previousApplication?.activate(options:[]) }
        previousApplication = nil
        diagnostics()
    }
    func screenForBubble() -> NSScreen { NSScreen.screens.first(where: { $0.frame.contains(NSPoint(x:bubble.frame.midX,y:bubble.frame.midY)) }) ?? NSScreen.screens.first! }
    func screenKey(_ screen: NSScreen) -> String { String((screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0) }
    func restorePosition() {
        guard let screen = NSScreen.screens.first(where: { screenKey($0) == defaults.string(forKey:"lastScreen") }) ?? NSScreen.screens.first else { return }
        let point = defaults.string(forKey:"position." + screenKey(screen)).map(NSPointFromString) ?? NSPoint(x:32,y:180)
        bubble.setFrameOrigin(NSPoint(x:screen.frame.minX+min(max(point.x,4),screen.frame.width-68),y:screen.frame.minY+min(max(point.y,4),screen.frame.height-68)))
    }
    func savePosition() {
        let screen = screenForBubble(); let frame = screen.frame
        let point = NSPoint(x:min(max(bubble.frame.minX-frame.minX,4),frame.width-68),y:min(max(bubble.frame.minY-frame.minY,4),frame.height-68))
        defaults.set(NSStringFromPoint(point),forKey:"position." + screenKey(screen)); defaults.set(screenKey(screen),forKey:"lastScreen")
        bubble.setFrameOrigin(NSPoint(x:frame.minX+point.x,y:frame.minY+point.y)); positionPanel(); diagnostics()
    }
    func positionPanel() {
        defer { positionToast() }
        guard bubble != nil, panel != nil, !NSScreen.screens.isEmpty else { return }
        let frame = screenForBubble().visibleFrame
        let size = NSSize(width:min(panel.frame.width,frame.width-24),height:min(panel.frame.height,frame.height-24))
        let right = bubble.frame.maxX+12
        let x = right+size.width <= frame.maxX ? right : bubble.frame.minX-size.width-12
        let y = bubble.frame.maxY-size.height
        panel.setFrame(NSRect(x:min(max(x,frame.minX+12),frame.maxX-size.width-12),y:min(max(y,frame.minY+12),frame.maxY-size.height-12),width:size.width,height:size.height),display:true)
    }
    @objc func screensChanged() { restorePosition(); positionPanel() }
    @objc func spaceChanged() { if visible { bubble.orderFrontRegardless(); if panelOpen { panel.orderFrontRegardless() }; toast?.orderFrontRegardless() } }
    var rosterMode: String { defaults.string(forKey:"rosterMode") == "shepherdr" ? "shepherdr" : "herdr" }
    @objc func refresh() {
        guard visible, !polling else { return }; polling = true
        let mode = rosterMode
        work.async { var data = self.client.snapshot(); self.decorateOrcaSnapshot(&data); if mode == "shepherdr" { data["shepherdr"] = self.shepherdr.overlay(agents:data["agents"] as? [Row] ?? []) }; DispatchQueue.main.async {
            self.polling = false; self.lastSnapshot = data;
            let online = Set((data["agents"] as? [Row] ?? []).filter { $0["online"] as? Bool == true }.compactMap { $0["id"] as? String })
            for id in Array(self.codexApprovals.keys) where !online.contains(id) { self.stopCodexApprovals(id,status:"This terminal is no longer available.") }
 if self.visible { self.emit("roster",data) }; self.diagnostics()
        } }
    }
    func emit(_ type: String, _ data: Row) { guard ready else { return }; web.evaluateJavaScript("window.receive(" + encode(["type":type,"data":data]) + ")") { _,error in if let error=error as NSError? {let detail=error.userInfo["WKJavaScriptExceptionMessage"] as? String ?? error.localizedDescription;try? encode(["event":type,"error":detail]).write(to:self.support.appendingPathComponent("ui-error.json"),atomically:true,encoding:.utf8)} } }
    func userContentController(_ userContentController: WKUserContentController,didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let data = message.body as? Row, let operation = data["op"] as? String else { return }
        let requestID = data["requestID"] as? String ?? ""
        switch operation {
        case "ready": ready = true; emit("preferences",["selectedAgent":defaults.string(forKey:"selectedAgent") ?? "","rosterWidth":defaults.double(forKey:"rosterWidth"),"mode":defaults.string(forKey:"viewMode") ?? "chat","rosterMode":rosterMode,"shepherdrSupported":true,"previewsSupported":true,"nativeFileAttachmentsSupported":client.usesHC,"attachmentsSupported":true,"videoAttachmentsSupported":self.client.usesHC,"markdownAttachmentsSupported":self.client.usesHC,"pdfAttachmentsSupported":self.client.usesHC,"wordAttachmentsSupported":self.client.usesHC,"agentHandoffSupported":self.client.usesHC,"terminalControlsSupported":self.client.usesHC,"nativeApprovalsSupported":self.client.usesHC,"orcaModelsSupported":self.client.usesHC,"draftsSupported":true,"chatTools":defaults.dictionary(forKey:"chatTools") ?? [:],"quickPromptsSupported":true,"quickPrompts":(try? QuickPrompts.validate(self.defaults.array(forKey:"quickPrompts"))) ?? QuickPrompts.defaults]); emit("visibility",["open":panelOpen]); if !lastSnapshot.isEmpty { emit("roster",lastSnapshot) }; if !hotkeyWarning.isEmpty { emit("notice",["message":hotkeyWarning]) }
            if CommandLine.arguments.contains("--orca-models") {openPanel();emit("openOrcaModels",[:])}
        case "orcaModels":
            guard client.usesHC,panelOpen,!requestID.isEmpty else { emit(operation,["requestID":requestID,"error":"Open the HUD to load OrcaRouter models."]);return }
            orcaCatalogWork.async {
                var result:Row
                do { result = try self.orcaModels.catalog() } catch { result = ["error":error.localizedDescription] }
                result["requestID"]=requestID;let value=result
                DispatchQueue.main.async { self.emit(operation,value) }
            }
        case "orcaLaunch":
            guard client.usesHC,panelOpen,!orcaLaunching,!requestID.isEmpty,let modelID=data["model"] as? String else { emit(operation,["requestID":requestID,"error":"Open the model picker and select a model."]);return }
            guard !promptIDs.contains(requestID) else { return };promptIDs.insert(requestID);orcaLaunching=true
            orcaCatalogWork.async {
                do {
                    let catalog=try self.orcaModels.catalog()
                    guard let models=catalog["models"] as? [Row],let model=models.first(where:{$0["id"] as? String == modelID}) else { throw HUDError("This model no longer meets your catalog filters. Refresh the list.") }
                    DispatchQueue.main.async {
                        guard self.panelOpen else {self.orcaLaunching=false;self.emit(operation,["requestID":requestID,"cancelled":true]);return}
                        let picker=NSOpenPanel();picker.canChooseFiles=false;picker.canChooseDirectories=true;picker.allowsMultipleSelection=false;picker.prompt="Open OpenCode";picker.message="Choose the project folder for this new OrcaRouter OpenCode chat."
                        picker.begin { response in
                            guard response == .OK,let url=picker.url else {self.orcaLaunching=false;self.emit(operation,["requestID":requestID,"cancelled":true]);return}
                            self.work.async {
                                var result:Row
                                do {result=try self.orcaLauncher.launch(directory:url.path,model:model)}catch{result=["error":error.localizedDescription]}
                                result["requestID"]=requestID;let value=result
                                DispatchQueue.main.async{self.orcaLaunching=false;self.emit(operation,value);self.refresh()}
                            }
                        }
                    }
                } catch {let message=error.localizedDescription;DispatchQueue.main.async{self.orcaLaunching=false;self.emit(operation,["requestID":requestID,"error":message])}}
            }
        case "orcaReconcile":
            guard client.usesHC,panelOpen,let id=data["id"] as? String,id==selected,!requestID.isEmpty else {emit(operation,["requestID":requestID,"error":"Select the same OpenCode chat before reconciling."]);return}
            work.async {
                var result:Row=["id":id,"requestID":requestID]
                do {let row=try self.client.hc.resolve(id);guard let adapter=try self.orcaLauncher.adapter(for:row) else {throw HUDError("This OpenCode session is not managed by the HUD.")};_=try adapter.reconcile();self.orcaUncertain.remove(id);result["ok"]=true}
                catch {result["error"]=error.localizedDescription};let value=result
                DispatchQueue.main.async{self.emit(operation,value);self.refresh()}
            }
        case "nativeApprovals":
            guard client.usesHC,panelOpen,let id=data["id"] as? String else { return }
            syncCodexApprovals(id,reconnect:data["reconnect"] as? Bool == true)
        case "nativeSteer":
            guard client.usesHC,panelOpen,let id=data["id"] as? String,id==selected,!requestID.isEmpty,
                  let turn=data["expectedTurnId"] as? String,let message=data["message"] as? String else {
                emit("nativeSteer",["requestID":requestID,"id":data["id"] as? String ?? "","error":"The selected Codex session changed. Your draft is retained.","uncertain":false]);return
            }
            performNativeSteer(id:id,turn:turn,message:message,attachments:data["attachments"],requestID:requestID)
        case "nativeSteerReconcile":
            guard panelOpen,let id=data["id"] as? String,id==selected else{emit("nativeSteerReconcile",["requestID":requestID,"id":data["id"] as? String ?? "","error":"Select the same Codex chat before reconciling."]);return}
            reconcileNativeSteer(id:id,requestID:requestID)
        case "nativeApprovalResponse":
            guard client.usesHC,panelOpen,let id=data["id"] as? String,id==selected,
                  let token=data["token"] as? String,let choice=data["choice"] as? String else { return }
            let epoch=codexApprovalEpochs[id],fingerprint=codexApprovalBindings[id]
            work.async {
                do {
                    let row=try self.client.hc.resolve(id)
                    guard let binding=try self.codexLauncher.binding(for:row),let fingerprint=fingerprint,encode(binding)==fingerprint else { throw HUDError("This session binding changed. Reconnect and review the approval again.") }
                    DispatchQueue.main.async {
                        var result:Row=["requestID":requestID,"id":id]
                        do {
                            guard self.panelOpen,self.selected==id,self.codexApprovalEpochs[id]==epoch,self.codexApprovalBindings[id]==fingerprint,let bridge=self.codexApprovals[id] else { throw HUDError("Selected session changed. Review the approval again.") }
                            try bridge.respond(token:token,choice:choice);result["ok"]=true
                        } catch { result["error"]=error.localizedDescription }
                        self.emit("nativeApprovalResponse",result)
                    }
                } catch {
                    let message=error.localizedDescription
                    DispatchQueue.main.async { self.stopCodexApprovals(id,status:message,preserveLink:true);self.emit("nativeApprovalResponse",["requestID":requestID,"id":id,"error":message]) }
                }
            }
        case "newCodexSession":
            guard client.usesHC,panelOpen,!launchingCodex else { return }
            launchingCodex=true
            let picker=NSOpenPanel();picker.canChooseFiles=false;picker.canChooseDirectories=true;picker.allowsMultipleSelection=false;picker.prompt="Start new Codex";picker.message="Choose the project folder for a new Codex session with HUD approvals."
            picker.beginSheetModal(for:panel) { response in
                guard response == .OK,let url=picker.url else { self.launchingCodex=false;self.emit("newCodexSession",["cancelled":true]);return }
                self.launchingCodex=true
                self.work.async {
                    var result:Row
                    do { let launched=try self.codexLauncher.launch(directory:url.path);guard let agent=launched["agent"] as? Row,let id=agent["id"] as? String else { throw HUDError("Session started but could not be selected. Check Herdr.") };result=["id":id] }
                    catch { result=["error":error.localizedDescription] }
                    let value=result
                    DispatchQueue.main.async { self.launchingCodex=false;self.emit("newCodexSession",value);self.refresh() }
                }
            }
        case "fileBegin", "fileChunk", "fileFinish", "fileCancel", "openFile", "videoBegin", "videoChunk", "videoFinish", "videoCancel", "videoImport", "openVideo", "pdfImport", "openPDF", "wordImport", "openWord":
            guard client.usesHC,!requestID.isEmpty,let id=data["id"] as? String,(["videoCancel","fileCancel"].contains(operation) || (panelOpen && (["openFile","openVideo","openPDF","openWord"].contains(operation) || id==selected))) else {emit(operation,["requestID":requestID,"error":"Select the same local chat before attaching video."]);return}
            let offer = operation == "videoImport" ? videoOffers.removeValue(forKey:data["offer"] as? String ?? "") : nil
            videoWork.async {
                var result:Row=["requestID":requestID,"id":id]
                do {
                    if operation == "fileBegin" {
                        guard let name=data["name"] as? String,let bytes=data["bytes"] as? Int else{throw HUDError("Invalid file upload.")}
                        let token=try self.fileStore.begin(name:name,bytes:bytes);self.fileImports[token]=id;result["token"]=token
                    } else if ["fileChunk","fileFinish","fileCancel"].contains(operation) {
                        guard let token=data["token"] as? String,self.fileImports[token]==id else{throw HUDError("File upload changed. Attach the file again.")}
                        if operation == "fileChunk" {guard let offset=data["offset"] as? Int,let bytes=data["data"] as? String else{throw HUDError("Invalid file chunk.")};try self.fileStore.append(token:token,offset:offset,dataBase64:bytes)}
                        else if operation == "fileFinish" {
                            defer{self.fileStore.cancel(token:token);self.fileImports.removeValue(forKey:token)}
                            result["attachment"]=try self.fileStore.finish(token:token){url,name in
                                if url.pathExtension=="pdf" {return try self.pdfStore.importFile(url,name:name)}
                                if url.pathExtension=="docx" {return try self.wordStore.importFile(url,name:name)}
                                return try self.fileStore.importFile(url,name:name)
                            }
                        } else {self.fileStore.cancel(token:token);self.fileImports.removeValue(forKey:token)}
                    } else if operation == "openFile" {
                        let item=data["attachment"] as? Row ?? [:],url=try self.fileStore.reference(item)
                        DispatchQueue.main.async {self.wordPreview?.stop();let preview=WordPreview(url:url,name:item["name"] as? String ?? "Attachment preview");self.wordPreview=preview;preview.window?.level=NSWindow.Level(rawValue:self.panel.level.rawValue+1);preview.showWindow(nil);preview.window?.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)}
                    } else if operation == "wordImport" {
                        guard let name=data["name"] as? String,let bytes=data["data"] as? String else{throw HUDError("Invalid Word attachment.")}
                        result["attachment"]=try self.wordStore.importData(name:name,dataBase64:bytes)
                    } else if operation == "openWord" {
                        let url=try self.wordStore.reference(data["attachment"] as? Row ?? [:])
                        DispatchQueue.main.async {self.wordPreview?.stop();let preview=WordPreview(url:url,name:(data["attachment"] as? Row)?["name"] as? String ?? "Word preview");self.wordPreview=preview;preview.window?.level=NSWindow.Level(rawValue:self.panel.level.rawValue+1);preview.showWindow(nil);preview.window?.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)}
                    } else if operation == "pdfImport" {
                        guard let name=data["name"] as? String,let bytes=data["data"] as? String else{throw HUDError("Invalid PDF attachment.")}
                        result["attachment"]=try self.pdfStore.importData(name:name,dataBase64:bytes)
                    } else if operation == "openPDF" {
                        let url=try self.pdfStore.reference(data["attachment"] as? Row ?? [:])
                        DispatchQueue.main.async {self.pdfPreview?.stop();let preview=PDFPreview(url:url,name:(data["attachment"] as? Row)?["name"] as? String ?? "PDF preview");self.pdfPreview=preview;preview.window?.level=NSWindow.Level(rawValue:self.panel.level.rawValue+1);preview.showWindow(nil);preview.window?.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)}
                    } else if operation == "openVideo" {
                        let url=try self.videoStore.reference(data["attachment"] as? Row ?? [:])
                        DispatchQueue.main.async {self.videoPreview?.stop();let preview=VideoPreview(url:url,name:(data["attachment"] as? Row)?["name"] as? String ?? "Video preview");self.videoPreview=preview;preview.window?.level=NSWindow.Level(rawValue:self.panel.level.rawValue+1);preview.showWindow(nil);preview.window?.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)}
                    } else if operation == "videoImport" {
                        guard let offer=offer,offer.1==id,Date().timeIntervalSince(offer.2)<60,offer.0.count<=3 else{throw HUDError("File drop expired. Drop or paste the files again.")}
                        result["attachments"]=try offer.0.map{url in
                            if url.pathExtension.lowercased() == "docx" {return try self.wordStore.importFile(url)}
                            if url.pathExtension.lowercased() == "pdf" {return try self.pdfStore.importFile(url)}
                            if FileAttachments.kind(name:url.lastPathComponent) != nil {return try self.fileStore.importFile(url)}
                            return try self.videoStore.importFile(url)
                        }
                    } else if operation == "videoBegin" {
                        guard let name=data["name"] as? String,let bytes=data["bytes"] as? Int else{throw HUDError("Invalid video attachment.")}
                        let token=try self.videoStore.begin(name:name,bytes:bytes);self.videoImports[token]=id;result["token"]=token
                    } else {
                        guard let token=data["token"] as? String,self.videoImports[token]==id else{throw HUDError("Video upload changed. Attach the file again.")}
                        if operation == "videoChunk" {guard let offset=data["offset"] as? Int,let bytes=data["data"] as? String else{throw HUDError("Invalid video chunk.")};try self.videoStore.append(token:token,offset:offset,dataBase64:bytes)}
                        else if operation == "videoFinish" {result["attachment"]=try self.videoStore.finish(token:token);self.videoImports.removeValue(forKey:token)}
                        else {self.videoStore.cancel(token:token);self.videoImports.removeValue(forKey:token)}
                    }
                    result["ok"]=true
                }catch{result["error"]=error.localizedDescription}
                let value=result;DispatchQueue.main.async{self.emit(operation,value)}
            }
        case "loadDrafts", "saveDrafts":
            guard !requestID.isEmpty else { return }
            draftWork.async {
                var result: Row = ["requestID":requestID]
                do {
                    if operation == "loadDrafts" { result["snapshot"] = try self.draftStore.load() }
                    else {let snapshot=try DraftStore.validate(data["snapshot"] ?? [:]);try self.videoWork.sync {var seen=Set<String>();for row in snapshot["drafts"] as? [Row] ?? [] {let groups=[row["images"] as? [Row] ?? []]+(row["queue"] as? [Row] ?? []).map{$0["images"] as? [Row] ?? []};for group in groups {for item in group where ["raster","markdown","video","pdf","word"].contains(item["kind"] as? String ?? "") && item["token"] != nil {if let token=item["token"] as? String,seen.insert((item["kind"] as! String)+token).inserted {if ["raster","markdown"].contains(item["kind"] as? String ?? "") {_ = try self.fileStore.reference(item,verifyContent:false)}else if item["kind"] as? String == "word" {_ = try self.wordStore.reference(item,verifyContent:false)}else if item["kind"] as? String == "pdf" {_ = try self.pdfStore.reference(item,verifyContent:false)}else{_ = try self.videoStore.reference(item,verifyContent:false)}}}}}};try self.draftStore.save(snapshot); result["ok"] = true }
                } catch { result["error"] = error.localizedDescription }
                let value=result
                DispatchQueue.main.async { self.emit(operation,value) }
            }
        case "saveQuickPrompts":
            do { let prompts=try QuickPrompts.validate(data["prompts"]); defaults.set(prompts,forKey:"quickPrompts"); emit("quickPrompts",["prompts":prompts]) }
            catch { emit("notice",["message":error.localizedDescription]) }
        case "openFileLink":
            guard panelOpen,client.usesHC,let id=data["id"] as? String,id==selected,let token=data["token"] as? String else { return }
            work.async {
                do {
                    let row=try self.client.hc.resolve(id)
                    guard row["machine_id"] as? String == "local" else { throw HUDError("Open files on their local machine.") }
                    let url=try self.fileLinks.resolve(agent:id,token:token)
                    DispatchQueue.main.async {
                        // Never launch an executable from terminal output. Source/text opens
                        // in TextEdit, raster/PDF in Preview, office files in read-only Quick Look.
                        let ext=url.pathExtension.lowercased()
                        if FileLinks.documents.contains(ext) {
                            let process=Process();process.executableURL=URL(fileURLWithPath:"/usr/bin/qlmanage");process.arguments=["-p",url.path]
                            process.standardOutput=FileHandle.nullDevice;process.standardError=FileHandle.nullDevice
                            do { try process.run() } catch { self.emit("notice",["message":"Could not preview this document."]) }
                        } else {
                            let app=FileLinks.images.contains(ext) ? "Preview" : "TextEdit"
                            NSWorkspace.shared.open([url],withApplicationAt:URL(fileURLWithPath:"/System/Applications/"+app+".app"),configuration:NSWorkspace.OpenConfiguration()) { _,error in
                                if error != nil { DispatchQueue.main.async { self.emit("notice",["message":"Could not open this file."]) } }
                            }
                        }
                    }
                } catch { let message=error.localizedDescription; DispatchQueue.main.async { self.emit("notice",["message":message]) } }
            }
        case "close": closePanel()
        case "hide": if visible { toggleVisibility() }
        case "refresh": refresh()
        case "preferences":
            if let id = data["chatID"] as? String, !id.isEmpty, id.utf8.count <= 8192,
               let options = data["chatTools"] as? [String:Bool],
               let shortcuts = options["shortcuts"], let handoff = options["handoff"] {
                var saved = defaults.dictionary(forKey:"chatTools") ?? [:]
                if shortcuts || handoff { saved[id] = ["shortcuts":shortcuts, "handoff":handoff] }
                else { saved.removeValue(forKey:id) }
                defaults.set(saved, forKey:"chatTools")
            }
            if let id = data["selectedAgent"] as? String, id.utf8.count <= 8192 { defaults.set(id,forKey:"selectedAgent") }
            if let width = data["rosterWidth"] as? Double, width >= 155 && width <= 600 { defaults.set(width,forKey:"rosterWidth") }
            if let mode = data["mode"] as? String, ["chat","terminal"].contains(mode) { defaults.set(mode,forKey:"viewMode") }
            if let mode = data["rosterMode"] as? String, ["herdr","shepherdr"].contains(mode), mode != rosterMode { defaults.set(mode,forKey:"rosterMode"); refresh() }
        case "previews", "choosePreviewFolder", "openPreview":
            guard panelOpen, let id = data["id"] as? String,
                  let row = (lastSnapshot["agents"] as? [Row])?.first(where: { $0["id"] as? String == id }),
                  row["machine_id"] as? String == "local", row["online"] as? Bool == true else { return }
            if operation == "choosePreviewFolder" {
                let picker = NSOpenPanel()
                picker.title = "Choose local preview folder"
                picker.canChooseDirectories = true; picker.canChooseFiles = false; picker.allowsMultipleSelection = false
                picker.beginSheetModal(for:panel) { response in
                    guard response == .OK, let url = picker.url, PreviewGallery.localDirectory(url) else { return }
                    var folders = self.defaults.dictionary(forKey:"previewFolders") as? [String:String] ?? [:]
                    folders[id] = url.path; self.defaults.set(folders,forKey:"previewFolders")
                    self.emit("previewFolderChanged",["id":id])
                }
            } else if operation == "previews" { loadPreviews(id,requestID:requestID) }
            else if let token = data["token"] as? String {
                work.async {
                    do {
                        if self.client.usesHC { _ = try self.client.hc.resolve(id) }
                        self.previewWork.async {
                    do {
                        let url = try self.previews.snapshot(agent:id,token:token)
                        DispatchQueue.main.async {
                            let configuration = NSWorkspace.OpenConfiguration()
                            NSWorkspace.shared.open([url],withApplicationAt:URL(fileURLWithPath:"/System/Applications/Preview.app"),configuration:configuration) { _,error in
                                if error != nil { DispatchQueue.main.async { self.emit("notice",["message":"Could not open this image in Preview."]) } }
                            }
                        }
                    } catch { let message = error.localizedDescription; DispatchQueue.main.async { self.emit("notice",["message":message]) } }
                    }
                    } catch { let message = error.localizedDescription; DispatchQueue.main.async { self.emit("notice",["message":message]) } }
                }
            }
        case "badge": bubbleView.count = data["count"] as? Int ?? 0
        case "alertPreview":
            if !panelOpen && visible, let id = data["id"] as? String {
                work.async {
                    let output = (try? self.client.output(id)) ?? ["id":id,"text":"","provider":""]
                    DispatchQueue.main.async { self.emit("alertPreview",output.merging(["title":data["title"] ?? "Agent update"],uniquingKeysWith:{_,b in b})) }
                }
            }
        case "alert": if !panelOpen && visible { showToast(data) }
        case "openModelPicker", "modelPickerKey", "reconcileModelPicker":
            let id = data["id"] as? String ?? ""
            guard panelOpen, client.usesHC, !id.isEmpty, id == selected,
                  defaults.string(forKey:"selectedAgent") == id, !requestID.isEmpty else {
                emit(operation,["id":id,"requestID":requestID,"error":"Select the same local chat before using its model picker."])
                return
            }
            guard promptIDs.insert(requestID).inserted else { return }
            work.async {
                let stillSelected = {
                    DispatchQueue.main.sync {
                        self.panelOpen && self.selected == id && self.defaults.string(forKey:"selectedAgent") == id
                    }
                }
                var result: Row = ["id":id,"requestID":requestID]
                do {
                    if operation == "openModelPicker" { try self.client.hc.openModelPicker(id,stillSelected:stillSelected) }
                    else if operation == "reconcileModelPicker" { try self.client.hc.reconcileModelPicker(id,stillSelected:stillSelected) }
                    else {
                        try self.client.hc.modelPickerKey(id,token:data["token"] as? String ?? "",
                                                        key:data["key"] as? String ?? "",stillSelected:stillSelected)
                    }
                    result["ok"] = true
                } catch {
                    result["error"] = error.localizedDescription
                    result["uncertain"] = self.client.hc.modelPickerUncertain.contains(id)
                }
                let reply = result
                DispatchQueue.main.async { self.emit(operation,reply) }
            }
        case "terminalKey", "approvalChoice", "reconcileTerminalKeys":
            guard panelOpen, self.client.usesHC, let id = data["id"] as? String, id == selected, !requestID.isEmpty else { return }
            guard !promptIDs.contains(requestID) else { return }; promptIDs.insert(requestID)
            work.async {
                var result: Row
                do {
                    if operation == "reconcileTerminalKeys" { try self.client.hc.reconcileTerminalKeys(id); result = ["id":id,"ok":true] }
                    else if operation == "approvalChoice" { result = try self.client.hc.approvalChoice(id,token:data["token"] as? String ?? "",key:data["key"] as? String ?? "") }
                    else { result = try self.client.hc.terminalKey(id,token:data["token"] as? String ?? "",key:data["key"] as? String ?? "") }
                } catch { result = ["id":id,"error":error.localizedDescription] }
                result["requestID"] = requestID
                let value = result
                DispatchQueue.main.async { self.emit(operation,value) }
            }
        case "output", "prompt", "queuedPrompt":
            guard let id = data["id"] as? String, !requestID.isEmpty else { return }
            if !panelOpen && operation != "queuedPrompt" {
                emit(operation,["id":id,"requestID":requestID,"error":"HUD panel closed before delivery. Your draft is retained."])
                return
            }
            if operation == "output" { if readBusy { return }; readBusy = true; selected = id }
            if operation != "output" { guard !promptIDs.contains(requestID) else { return }; promptIDs.insert(requestID) }
            work.async {
                var result: Row
                do {
                    if operation == "queuedPrompt" {
                        let snapshot = try self.draftWork.sync { try self.draftStore.load() }
                        try DraftStore.authorizeQueuedPrompt(snapshot, id:id, token:data["queueToken"] as? String ?? "", text:data["message"] as? String ?? "", attachments:data["attachments"])
                        let claim = encode([id,data["queueToken"] as? String ?? ""])
                        guard self.queuedPromptClaims.insert(claim).inserted else { throw HUDError("Queued delivery was already attempted. Inspect Herdr; it will not be retried.") }
                    }
                    if operation == "output" {result = id.hasPrefix("shepherdr:") ? try self.shepherdr.transcript(String(id.dropFirst(10))) : try self.client.output(id)}
                    else if self.client.usesHC {
                        let row=try self.client.hc.resolve(id)
                        try self.prepareMedia(message:data["message"] as? String ?? "",attachments:data["attachments"],row:row) { preparation in
                            var delivered:Row
                            do {
                                let prepared=try preparation.get()
                                // Preparation can take minutes. Bind and check readiness again on
                                // the transport queue before any upload or prompt mutation.
                                let current=try self.client.hc.resolve(id)
                                if current["agent"] as? String == "opencode" {
                                    guard let adapter=try self.orcaLauncher.adapter(for:current) else {throw HUDError("This OpenCode session is not managed by the HUD.")}
                                    guard !self.orcaUncertain.contains(id) else {throw HUDError("OpenCode delivery uncertain. Inspect Herdr before sending again.")}
                                    delivered=try adapter.prompt(text:prepared.0,attachments:ImageAttachment.parse(prepared.1));delivered["id"]=id
                                }else{delivered=try self.client.prompt(id,prepared.0,attachments:prepared.1)}
                            }catch {
                                let unknown=(error as? OrcaOpenCode.Failure)?.uncertain ?? false
                                if unknown{self.orcaUncertain.insert(id)}
                                delivered=["error":error.localizedDescription,"id":id,"uncertain":unknown]
                            }
                            delivered["requestID"]=requestID;let value=delivered
                            DispatchQueue.main.async{self.emit(operation,value)}
                        }
                        return
                    } else {result=try self.client.prompt(id,data["message"] as? String ?? "",attachments:data["attachments"])}
                }
                catch {let unknown=(error as? OrcaOpenCode.Failure)?.uncertain ?? false;if unknown{self.orcaUncertain.insert(id)};result = ["error":error.localizedDescription, "id":id,"uncertain":unknown] }
                if operation == "output", result["error"] == nil, self.client.usesHC,
                   let row=self.client.hc.bindings[id],row["machine_id"] as? String == "local",let directory=row["preview_directory"] as? String {
                    result["files"]=self.fileLinks.discover(agent:id,output:result["text"] as? String ?? "",directory:directory)
                }
                result["requestID"] = requestID
                let value = result
                DispatchQueue.main.async { if operation == "output" { self.readBusy = false }; self.emit(operation,value);if operation == "output",self.client.usesHC { self.syncCodexApprovals(id) } }
            }
        default: break
        }
    }
    func decorateOrcaSnapshot(_ data:inout Row) {
        guard client.usesHC,var rows=data["agents"] as? [Row] else{return}
        for index in rows.indices where rows[index]["agent"] as? String == "opencode" {
            do {
                guard let adapter=try orcaLauncher.adapter(for:rows[index]) else{continue}
                let state=try adapter.snapshot()
                rows[index]["agent_status"]=state["agent_status"];rows[index]["input_kind"]=state["input_kind"]
                let id=rows[index]["id"] as? String ?? ""
                if state["uncertain"] as? Bool == true{orcaUncertain.insert(id)}
                rows[index]["can_prompt"]=(state["canPrompt"] as? Bool == true) && !orcaUncertain.contains(id);rows[index]["can_attach"]=true
                rows[index]["orca_managed"]=true;rows[index]["orca_uncertain"]=orcaUncertain.contains(id)
                rows[index]["orca_model"]=state["modelID"]
            }catch{rows[index]["agent_status"]="unknown";rows[index]["can_prompt"]=false;rows[index]["orca_error"]=error.localizedDescription}
        }
        data["agents"]=rows
    }
    @objc func closeVideoPreview() {videoPreview?.stop();videoPreview=nil;pdfPreview?.stop();pdfPreview=nil;wordPreview?.stop();wordPreview=nil}
    @objc func pasteWithVideos(_ sender:Any?) {
        if panelOpen,NSApp.keyWindow === panel,(web as? VideoWebView)?.pasteVideos() == true {return}
        NSApp.sendAction(NSSelectorFromString("paste:"),to:nil,from:sender)
    }
    func offerVideos(_ urls:[URL]) {
        guard panelOpen,client.usesHC,!selected.isEmpty else{return}
        videoOffers=videoOffers.filter{Date().timeIntervalSince($0.value.2)<60}
        guard urls.count<=3,videoOffers.count<8 else{emit("notice",["message":"Attach up to three files at a time."]);return}
        let token=UUID().uuidString;videoOffers[token]=(urls,selected,Date())
        emit("videoOffer",["id":selected,"offer":token,"count":urls.count])
    }
    // Called on work; completion also runs on work. Slow decoding/recognition
    // has its own serial queue so roster, approvals and output keep refreshing.
    func prepareMedia(message:String,attachments:Any?,row:Row,completion:@escaping(Result<(String,[Row]),Error>)->Void)throws {
        guard attachments == nil || attachments is [Row] else{throw HUDError("Invalid attachments.")}
        let items=attachments as? [Row] ?? [];guard items.count<=3 else{throw HUDError("Attach up to three files.")}
        let videos=items.filter{$0["kind"] as? String == "video"}
        guard !items.contains(where:{["raster","video","markdown","pdf","word"].contains($0["kind"] as? String ?? "")}) || (row["machine_id"] as? String == "local" && ["claude","codex","opencode"].contains(row["agent"] as? String ?? "")) else{throw HUDError("File attachments require a local Claude, Codex or managed OpenCode chat.")}
        if items.contains(where:{["video","pdf"].contains($0["kind"] as? String ?? "")}) {
            if row["agent"] as? String == "opencode" {
                guard let adapter=try self.orcaLauncher.adapter(for:row) else {throw HUDError("Open this model through the HUD OrcaRouter picker first.")}
                try adapter.verifyCatalog(requireVision:true)
            }
            DispatchQueue.main.async {self.emit("notice",["message":"Preparing attachment visuals and local text analysis…"])}
        }
        if videos.isEmpty && !items.contains(where:{["pdf","word","raster"].contains($0["kind"] as? String ?? "") || $0["token"] != nil}) {completion(Result {try VideoMedia.prepare(message:message,items:items,resolve:{_ in throw HUDError("Unexpected video reference.")})});return}
        if items.contains(where:{$0["kind"] as? String == "word"}) {DispatchQueue.main.async {self.emit("notice",["message":"Preparing Word document text and embedded images…"])}}
        mediaPreparation.async {
            let prepared=Result {try VideoMedia.prepare(message:message,items:items,resolve:{item in
                try self.videoWork.sync {
                    if item["kind"] as? String == "word" {return try self.wordStore.reference(item)}
                    return item["kind"] as? String == "pdf" ? try self.pdfStore.reference(item) : try self.videoStore.reference(item)
                }
            },file:{item in try self.videoWork.sync {try self.fileStore.prepare(item)}},word:{url in try WordAnalysis.prepare(url:url,saveTranscript:{text,source in
                try self.videoWork.sync {try WordAnalysis.persist(text,url:source)}
            })},pdf:{url in try PDFAnalysis.prepare(url:url,saveTranscript:{text,source in
                try self.videoWork.sync {try PDFAnalysis.persist(text,url:source)}
            })})}
            self.work.async {completion(prepared)}
        }
    }
    func performNativeSteer(id:String,turn:String,message:String,attachments:Any?,requestID:String) {
        let epoch=codexApprovalEpochs[id],fingerprint=codexApprovalBindings[id]
        work.async {
            do {
                let row=try self.client.hc.resolve(id)
                guard row["agent_status"] as? String == "working",row["agent"] as? String == "codex",
                      let binding=try self.codexLauncher.binding(for:row),let fingerprint=fingerprint,encode(binding)==fingerprint else{throw HUDError("This working Codex session changed. Your draft is retained.")}
                try self.prepareMedia(message:message,attachments:attachments,row:row) {preparation in
                    do {
                        let prepared=try preparation.get(),images=try ImageAttachment.parse(prepared.1)
                        let current=try self.client.hc.resolve(id)
                        guard current["agent_status"] as? String == "working",current["agent"] as? String == "codex",
                              let binding=try self.codexLauncher.binding(for:current),encode(binding)==fingerprint else{throw HUDError("This working Codex session changed. Your draft is retained.")}
                        DispatchQueue.main.async {
                            guard self.panelOpen,self.selected==id,!self.codexSteerUncertain.contains(id),self.codexApprovalEpochs[id]==epoch,self.codexApprovalBindings[id]==fingerprint,let bridge=self.codexApprovals[id] else {
                                self.emit("nativeSteer",["requestID":requestID,"id":id,"error":"The selected Codex session changed. Your draft is retained.","uncertain":false]);return
                            }
                            // Private image copying and validation stay off the UI thread.
                            self.work.async {
                                do {
                                    try bridge.steer(expectedTurnID:turn,text:prepared.0,attachments:images){result in
                                        if result["uncertain"] as? Bool == true{self.codexSteerUncertain.insert(id)}
                                        self.emit("nativeSteer",result.merging(["requestID":requestID,"id":id],uniquingKeysWith:{_,new in new}))
                                    }
                                }catch {
                                    let error=error.localizedDescription
                                    DispatchQueue.main.async{self.emit("nativeSteer",["requestID":requestID,"id":id,"error":error,"uncertain":false])}
                                }
                            }
                        }
                    }catch {
                        let error=error.localizedDescription
                        DispatchQueue.main.async{self.emit("nativeSteer",["requestID":requestID,"id":id,"error":error,"uncertain":false])}
                    }
                }
            }catch {
                let error=error.localizedDescription
                DispatchQueue.main.async{self.emit("nativeSteer",["requestID":requestID,"id":id,"error":error,"uncertain":false])}
            }
        }
    }
    func reconcileNativeSteer(id:String,requestID:String) {
        let epoch=codexApprovalEpochs[id],fingerprint=codexApprovalBindings[id]
        work.async {
            do {
                let row=try self.client.hc.resolve(id)
                guard let binding=try self.codexLauncher.binding(for:row),let fingerprint=fingerprint,encode(binding)==fingerprint else{throw HUDError("This Codex session binding changed. Reconnect and inspect it.")}
                DispatchQueue.main.async {
                    var result:Row=["requestID":requestID,"id":id]
                    do {
                        guard self.panelOpen,self.selected==id,self.codexApprovalEpochs[id]==epoch,self.codexApprovalBindings[id]==fingerprint,let bridge=self.codexApprovals[id] else{throw HUDError("Select the same Codex chat before reconciling.")}
                        try bridge.reconcileSteer();self.codexSteerUncertain.remove(id);result["ok"]=true
                    }catch{result["error"]=error.localizedDescription}
                    self.emit("nativeSteerReconcile",result)
                }
            }catch{let message=error.localizedDescription;DispatchQueue.main.async{self.emit("nativeSteerReconcile",["requestID":requestID,"id":id,"error":message])}}
        }
    }
    func stopCodexApprovals(_ id:String,status:String,preserveLink:Bool=false) {
        let thread=codexApprovalStates[id]?["threadId"] as? String ?? ""
        if preserveLink { codexApprovalInvalid.insert(id) }
        codexApprovalBindings.removeValue(forKey:id)
        codexApprovalEpochs.removeValue(forKey:id)
        codexApprovals.removeValue(forKey:id)?.disconnect()
        let state:Row=["id":id,"linked":preserveLink,"connected":false,"status":status,"cards":[],"threadId":thread,"canSteer":false,"activeTurnId":"","steerUncertain":codexSteerUncertain.contains(id)]
        codexApprovalStates[id]=state;emit("nativeApprovals",state)
    }
    func syncCodexApprovals(_ id:String,reconnect:Bool=false) {
        guard client.usesHC,!id.hasPrefix("shepherdr:") else { return }
        if reconnect { codexApprovalInvalid.remove(id);stopCodexApprovals(id,status:"Reconnecting…") }
        if codexApprovalInvalid.contains(id) { if let state=codexApprovalStates[id] { emit("nativeApprovals",state) };return }
        work.async {
            do {
                let row=try self.client.hc.resolve(id),binding=try self.codexLauncher.binding(for:row)
                DispatchQueue.main.async {
                    guard !self.codexApprovalInvalid.contains(id) else { return }
                    guard let binding=binding,let socket=binding["socket"] as? String,let thread=binding["threadID"] as? String else {
                        if self.codexApprovals[id] != nil { self.stopCodexApprovals(id,status:"This terminal is no longer linked.") }
                        else { self.emit("nativeApprovals",["id":id,"linked":false,"cards":[],"canSteer":false,"steerUncertain":self.codexSteerUncertain.contains(id)]) };return
                    }
                    if self.codexApprovals[id] != nil { guard self.codexApprovalBindings[id]==encode(binding) else { self.stopCodexApprovals(id,status:"Session binding changed. Reconnect and review the request.",preserveLink:true);return };if let state=self.codexApprovalStates[id] { self.emit("nativeApprovals",state) };return }
                    let epoch=UUID();self.codexApprovalEpochs[id]=epoch;self.codexApprovalBindings[id]=encode(binding)
                    let bridge=CodexApprovals(binary:NSHomeDirectory()+"/.local/bin/codex",socket:socket,threadID:thread,initialSteerUncertain:self.codexSteerUncertain.contains(id)) { [weak self=self] state in
                        guard let self=self,self.codexApprovalEpochs[id]==epoch else { return }
                        if state["steerUncertain"] as? Bool == true{self.codexSteerUncertain.insert(id)}
                        let blocked=self.codexSteerUncertain.contains(id)
                        let value=state.merging(["id":id,"linked":true,"steerUncertain":blocked,"canSteer":(state["canSteer"] as? Bool == true) && !blocked],uniquingKeysWith:{_,new in new})
                        self.codexApprovalStates[id]=value;self.emit("nativeApprovals",value)
                    }
                    self.codexApprovals[id]=bridge;bridge.connect()
                }
            } catch {
                let message=error.localizedDescription
                DispatchQueue.main.async { if self.codexApprovals[id] != nil { self.stopCodexApprovals(id,status:message) } }
            }
        }
    }
    func loadPreviews(_ id: String, requestID: String) {
        let folder = (defaults.dictionary(forKey:"previewFolders") as? [String:String])?[id]
        work.async {
            var result: Row
            do {
                let row = self.client.usesHC ? try self.client.hc.resolve(id) : [:]
                guard row.isEmpty || row["machine_id"] as? String == "local" else { throw HUDError("Previews are available for local agents only.") }
                guard let path = folder ?? row["preview_directory"] as? String, path.hasPrefix("/") else { throw HUDError("Choose the agent’s local project or output folder.") }
                self.previewWork.async {
                    var gallery: Row
                    do { gallery = try self.previews.list(agent:id,directory:URL(fileURLWithPath:path,isDirectory:true)) }
                    catch { gallery = ["id":id,"items":[],"error":error.localizedDescription] }
                    gallery["requestID"] = requestID
                    let value = gallery
                    DispatchQueue.main.async { self.emit("previews",value) }
                }
                return
            } catch { result = ["id":id,"items":[],"error":error.localizedDescription] }
            result["requestID"] = requestID
            let value = result
            DispatchQueue.main.async { self.emit("previews",value) }
        }
    }
    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        guard frame.isMainFrame, panelOpen else { completionHandler(nil); return }
        let picker = NSOpenPanel()
        picker.title = "Attach images, Markdown, PDF, Word or MP4 videos (up to 3 files)"
        picker.canChooseDirectories = false; picker.canChooseFiles = true; picker.allowsMultipleSelection = true
        picker.allowedContentTypes = [.png,.jpeg,.gif,UTType(filenameExtension:"webp") ?? .image,.mpeg4Movie,.pdf,UTType(filenameExtension:"docx") ?? .data,UTType(filenameExtension:"md") ?? .plainText,UTType(filenameExtension:"markdown") ?? .plainText]
        picker.beginSheetModal(for:panel) { response in
            completionHandler(response == .OK ? picker.urls : nil)
        }
    }
    func webView(_ webView: WKWebView,decidePolicyFor navigationAction: WKNavigationAction,decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        decisionHandler(url.isFileURL && url.standardizedFileURL.path == HUDResources.root.appendingPathComponent("index.html").standardizedFileURL.path && navigationAction.navigationType != .linkActivated ? .allow : .cancel)
    }
    func showToast(_ data: Row) {
        hideToast()
        let window = NSPanel(contentRect:NSRect(x:0,y:0,width:320,height:124),styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
        configure(window); window.title = "Herdr HUD Alert"
        window.level = NSWindow.Level(rawValue:bubble.level.rawValue+1)
        let view = ToastView(frame:NSRect(x:0,y:0,width:320,height:124)); view.app = self; view.agentID = data["id"] as? String ?? ""
        view.title = data["title"] as? String ?? "Agent update"; view.detail = data["preview"] as? String ?? "Click to read the response"
        window.contentView = view
        toast = window; positionToast(); window.orderFrontRegardless()
        toastTimer = Timer.scheduledTimer(withTimeInterval:8,repeats:false) { [weak self] _ in if self?.toastHover != true { self?.hideToast() } }
    }
    func positionToast() {
        guard let toast = toast, bubble != nil, !NSScreen.screens.isEmpty else { return }
        toast.setFrame(notificationFrame(bubble:bubble.frame,size:toast.frame.size,visibleFrame:screenForBubble().visibleFrame),display:true)
    }
    func hideToast() { toastTimer?.invalidate(); toast?.orderOut(nil); toast = nil; toastHover = false }
    func diagnostics() {
        guard bubble != nil else { return }
        let data: Row = ["pid":ProcessInfo.processInfo.processIdentifier,"visible":visible,"panelOpen":panelOpen,"screens":NSScreen.screens.count,"panelKey":panel.isKeyWindow,"appActive":NSApp.isActive,"panelNonactivating":panel.styleMask.contains(.nonactivatingPanel),"resourceRoot":HUDResources.root.path,"bubbleFrame":NSStringFromRect(bubble.frame),"panelFrame":NSStringFromRect(panel.frame),"machines":lastSnapshot["machines"] ?? [],"agentCount":(lastSnapshot["agents"] as? [Row])?.count ?? 0,"shortcutWarning":hotkeyWarning]
        try? encode(data).write(to:support.appendingPathComponent("diagnostics.json"),atomically:true,encoding:.utf8)
    }
    @objc func control(_ notification: Notification) {
        switch notification.object as? String {
        case "open": openPanel()
        case "orca-models": openPanel();emit("openOrcaModels",[:])
        case "close": closePanel()
        case "toggle": togglePanel()
        case "hide": if visible { toggleVisibility() }
        case "show": if !visible { toggleVisibility() }
        case "preview-alert":
            let foreground = NSWorkspace.shared.frontmostApplication?.processIdentifier
            showToast(["id":defaults.string(forKey:"selectedAgent") ?? "","title":"Notification preview","preview":"Implemented the card stack and arrow navigation. New captures join the stack, and clicking a thumbnail opens the full image. This longer notification demonstrates clean word boundaries without clipping the last line."])
            DispatchQueue.main.asyncAfter(deadline:.now()+0.25) {
                guard let toast = self.toast else { return }
                let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly,kCGNullWindowID) as? [Row] ?? []
                let toastIndex = windows.firstIndex { ($0[kCGWindowNumber as String] as? Int) == toast.windowNumber }
                let bubbleIndex = windows.firstIndex { ($0[kCGWindowNumber as String] as? Int) == self.bubble.windowNumber }
                let evidence: Row = ["bubbleFrame":NSStringFromRect(self.bubble.frame),"toastFrame":NSStringFromRect(toast.frame),"onScreen":self.screenForBubble().visibleFrame.contains(toast.frame),"overlapsButton":toast.frame.intersects(self.bubble.frame),"focusUnchanged":NSWorkspace.shared.frontmostApplication?.processIdentifier == foreground,"toastAboveButton":toastIndex != nil && bubbleIndex != nil && toastIndex! < bubbleIndex!,"visible":toast.isVisible]
                try? encode(evidence).write(to:self.support.appendingPathComponent("notification-preview.json"),atomically:true,encoding:.utf8)
                if let view = toast.contentView, let rep = view.bitmapImageRepForCachingDisplay(in:view.bounds) {
                    view.cacheDisplay(in:view.bounds,to:rep)
                    if let data = rep.representation(using:.png,properties:[:]) { try? data.write(to:self.support.appendingPathComponent("notification-preview.png")) }
                }
            }
        case "verify-ui":
            openPanel()
            web.callAsyncJavaScript("return await window.verifyControls()",arguments:[:],in:nil,in:.page) { result in
                let value: Any
                switch result { case .success(let data): value=data; case .failure(let error): value=["error":error.localizedDescription] }
                try? encode(value).write(to:self.support.appendingPathComponent("ui-verification.json"),atomically:true,encoding:.utf8)
            }
        case "inspect":
            web.evaluateJavaScript("JSON.stringify({title:document.title,agents:document.querySelectorAll('.agent').length,selected:document.getElementById('title').textContent,outputLength:document.getElementById('output').textContent.length,draftLength:document.getElementById('prompt').value.length,sendDisabled:document.getElementById('send').disabled,notice:document.getElementById('notice').textContent})") { value,error in
                let text = (value as? String) ?? (error?.localizedDescription ?? "unknown")
                try? text.write(to:self.support.appendingPathComponent("ui-check.json"),atomically:true,encoding:.utf8)
            }
        case "snapshot":
            web.takeSnapshot(with:nil) { image,error in
                if let image = image, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data:tiff), let data = rep.representation(using:.png,properties:[:]) { try? data.write(to:self.support.appendingPathComponent("panel-preview.png")) }
            }
        default: break
        }
    }
}
final class ToastView: NSView {
    weak var app: HUDApp?
    var agentID = "", title = "", detail = ""
    override func acceptsFirstMouse(for event:NSEvent?) -> Bool { true }
    override func updateTrackingAreas() { super.updateTrackingAreas(); for area in trackingAreas { removeTrackingArea(area) }; addTrackingArea(NSTrackingArea(rect:bounds,options:[.mouseEnteredAndExited,.activeAlways],owner:self)) }
    override func mouseEntered(with event:NSEvent) { app?.toastHover = true }
    override func mouseExited(with event:NSEvent) { app?.toastHover = false; app?.toastTimer?.invalidate(); app?.toastTimer = Timer.scheduledTimer(withTimeInterval:8,repeats:false) { [weak self] _ in self?.app?.hideToast() } }
    override func mouseUp(with event:NSEvent) { if convert(event.locationInWindow,from:nil).x > bounds.width-35 { app?.hideToast() } else { let id = agentID; app?.openPanel(); app?.emit("select",["id":id]) } }
    override func draw(_ dirtyRect:NSRect) {
        NSColor(calibratedWhite:0.10,alpha:0.98).setFill(); NSBezierPath(roundedRect:bounds,xRadius:14,yRadius:14).fill()
        let heading=NSMutableParagraphStyle();heading.lineBreakMode = .byTruncatingTail
        (title as NSString).draw(in:NSRect(x:16,y:91,width:270,height:18),withAttributes:[.font:NSFont.systemFont(ofSize:13,weight:.semibold),.foregroundColor:NSColor.systemGreen,.paragraphStyle:heading])
        let font=NSFont.systemFont(ofSize:12),body=ToastPreview.fitted(detail,font:font,width:282,height:46)
        (body as NSString).draw(in:NSRect(x:16,y:40,width:282,height:46),withAttributes:[.font:font,.foregroundColor:NSColor.white])
        ("Click to read full reply" as NSString).draw(at:NSPoint(x:16,y:15),withAttributes:[.font:NSFont.systemFont(ofSize:11),.foregroundColor:NSColor.lightGray])
        ("×" as NSString).draw(at:NSPoint(x:296,y:94),withAttributes:[.font:NSFont.systemFont(ofSize:18),.foregroundColor:NSColor.gray])
    }
}
