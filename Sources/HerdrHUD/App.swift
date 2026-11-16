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
        web = WKWebView(frame:panel.contentView!.bounds,configuration:config)
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
        let quitItem = menuItem("Quit Herdr HUD",#selector(quit))
        quitItem.keyEquivalent = "q"; applicationMenu.addItem(quitItem)
        application.submenu = applicationMenu; main.addItem(application)
        let edit = NSMenuItem(title:"Edit",action:nil,keyEquivalent:"")
        edit.submenu = editorMenu(); main.addItem(edit)
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
        work.async { var data = self.client.snapshot(); if mode == "shepherdr" { data["shepherdr"] = self.shepherdr.overlay(agents:data["agents"] as? [Row] ?? []) }; DispatchQueue.main.async {
            self.polling = false; self.lastSnapshot = data; if self.visible { self.emit("roster",data) }; self.diagnostics()
        } }
    }
    func emit(_ type: String, _ data: Row) { guard ready else { return }; web.evaluateJavaScript("window.receive(" + encode(["type":type,"data":data]) + ")",completionHandler:nil) }
    func userContentController(_ userContentController: WKUserContentController,didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let data = message.body as? Row, let operation = data["op"] as? String else { return }
        let requestID = data["requestID"] as? String ?? ""
        switch operation {
        case "ready": ready = true; emit("preferences",["selectedAgent":defaults.string(forKey:"selectedAgent") ?? "","rosterWidth":defaults.double(forKey:"rosterWidth"),"mode":defaults.string(forKey:"viewMode") ?? "chat","rosterMode":rosterMode,"shepherdrSupported":true,"previewsSupported":true,"attachmentsSupported":true]); emit("visibility",["open":panelOpen]); if !lastSnapshot.isEmpty { emit("roster",lastSnapshot) }; if !hotkeyWarning.isEmpty { emit("notice",["message":hotkeyWarning]) }
        case "close": closePanel()
        case "hide": if visible { toggleVisibility() }
        case "refresh": refresh()
        case "preferences":
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
        case "output", "prompt":
            guard let id = data["id"] as? String, !requestID.isEmpty, panelOpen else { return }
            if operation == "output" { if readBusy { return }; readBusy = true; selected = id }
            if operation == "prompt" { guard !promptIDs.contains(requestID) else { return }; promptIDs.insert(requestID) }
            work.async {
                var result: Row
                do { result = operation == "output" ? (id.hasPrefix("shepherdr:") ? try self.shepherdr.transcript(String(id.dropFirst(10))) : try self.client.output(id)) : try self.client.prompt(id,data["message"] as? String ?? "",attachments:data["attachments"]) }
                catch { result = ["error":error.localizedDescription, "id":id] }
                result["requestID"] = requestID
                let value = result
                DispatchQueue.main.async { if operation == "output" { self.readBusy = false }; self.emit(operation,value) }
            }
        default: break
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
        picker.title = "Attach images (up to 3, 4 MB each)"
        picker.canChooseDirectories = false; picker.canChooseFiles = true; picker.allowsMultipleSelection = true
        picker.allowedContentTypes = [.png,.jpeg,.gif,UTType(filenameExtension:"webp") ?? .image]
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
        let window = NSPanel(contentRect:NSRect(x:0,y:0,width:320,height:92),styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
        configure(window); window.title = "Herdr HUD Alert"
        window.level = NSWindow.Level(rawValue:bubble.level.rawValue+1)
        let view = ToastView(frame:NSRect(x:0,y:0,width:320,height:92)); view.app = self; view.agentID = data["id"] as? String ?? ""
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
        case "close": closePanel()
        case "toggle": togglePanel()
        case "hide": if visible { toggleVisibility() }
        case "show": if !visible { toggleVisibility() }
        case "preview-alert":
            let foreground = NSWorkspace.shared.frontmostApplication?.processIdentifier
            showToast(["id":defaults.string(forKey:"selectedAgent") ?? "","title":"Notification preview","preview":"Notifications follow H and stay clear of the button."])
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
        (title as NSString).draw(in:NSRect(x:16,y:50,width:270,height:26),withAttributes:[.font:NSFont.systemFont(ofSize:13,weight:.semibold),.foregroundColor:NSColor.systemGreen])
        (detail as NSString).draw(in:NSRect(x:16,y:12,width:282,height:36),withAttributes:[.font:NSFont.systemFont(ofSize:12),.foregroundColor:NSColor.white])
        ("×" as NSString).draw(at:NSPoint(x:296,y:65),withAttributes:[.font:NSFont.systemFont(ofSize:18),.foregroundColor:NSColor.gray])
    }
}
