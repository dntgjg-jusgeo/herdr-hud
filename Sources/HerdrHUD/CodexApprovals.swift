import Foundation
import CoreFoundation
import Darwin

/// A second, request-ID-bound client of an already-running dedicated Codex server.
/// Follow-ups use the exact native active-turn precondition; no terminal keys or retries.
final class CodexApprovals {
    struct WireID: Hashable {
        let key: String
        let value: AnyHashable
        init?(_ raw: Any?) {
            if let text = raw as? String, !text.isEmpty, text.utf8.count <= 512 { key="s:"+text;value=text;return }
            guard let number=raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  "csilqCSILQ".contains(String(cString:number.objCType)) else { return nil }
            key="n:"+number.stringValue;value=number
        }
        var json: Any { value.base }
        static func ==(a:Self,b:Self)->Bool { a.key == b.key }
        func hash(into hasher:inout Hasher) { hasher.combine(key) }
    }
    struct PendingSteer {let rpcID:String,turnID:String,clientID:String,started:TimeInterval}
    struct Card {
        let id:WireID, token:String, original:Data, question:String, detail:String, choices:[Row], turnID:String
        var sentAt:TimeInterval?
        var row:Row { ["token":token,"question":question,"detail":detail,"choices":choices,"pending":sentAt != nil] }
    }
    /// Pure protocol state, independently tested without a live server or model.
    struct ProtocolState {
        let threadID:String, epoch:String
        var cycle=0,turnGeneration=0,steerSequence=0
        var activeTurnID="",working=false,steerUncertain=false
        var model="",reasoningEffort=""
        var soliciting:[WireID:String]=[:],probeGeneration:Int?,probeID:String?,steerPending:PendingSteer?,steerOutcome:Row?
        var canSteer:Bool {connected && working && !activeTurnID.isEmpty && cards.isEmpty && soliciting.isEmpty && steerPending == nil && !steerUncertain}
        var phase="initialize", cards:[WireID:Card]=[:], order:[WireID]=[], resolved=Set<WireID>(), retiredTurns=Set<String>()
        init(threadID:String,epoch:String=UUID().uuidString) { self.threadID=threadID;self.epoch=epoch }
        var connected:Bool { phase == "ready" }
        var snapshot:Row { ["connected":connected,"status":phase == "waiting" ? "Waiting for the first prompt in this new Codex chat." : connected ? "Connected to Codex approvals." : "Connecting to Codex approvals…","cards":connected ? order.compactMap{cards[$0]?.row} : [Row](),"threadId":threadID,"canSteer":canSteer,"activeTurnId":activeTurnID,"steerUncertain":steerUncertain,"model":connected ? model:"","reasoningEffort":connected ? reasoningEffort:""] }
        func request(_ stage:String,_ method:String,_ params:Row)->Row { ["id":"hud-"+epoch+"-"+stage+(cycle == 0 ? "":"-"+String(cycle)),"method":method,"params":params] }
        func begin()->Row { request("initialize","initialize",["clientInfo":["name":"herdr_hud","title":"Herdr HUD","version":"1"],"capabilities":["experimentalApi":true]]) }
        mutating func receive(_ row:Row) throws -> [Row] {
            if let method=row["method"] as? String {
                let params=row["params"] as? Row ?? [:]
                if ["thread/closed","thread/archived","thread/deleted"].contains(method),params["threadId"] as? String == threadID {
                    throw HUDError("This Codex chat closed. Use its terminal to continue.")
                }
                if method == "thread/settings/updated",params["threadId"] as? String == threadID,let settings=params["threadSettings"] as? Row {
                    updateModel(settings,effortKey:"effort")
                    return []
                }
                if method == "turn/started",params["threadId"] as? String == threadID,let turn=params["turn"] as? Row {
                    turnGeneration += 1
                    if let id=turn["id"] as? String,!id.isEmpty,id.utf8.count<=512,!retiredTurns.contains(id),turn["status"] as? String == "inProgress" {activeTurnID=id;working=true}
                    else{activeTurnID="";working=false}
                    return []
                }
                if method == "thread/status/changed",params["threadId"] as? String == threadID,let status=params["status"] as? Row {
                    turnGeneration += 1
                    working=status["type"] as? String == "active" && (status["activeFlags"] as? [String]) == []
                    if status["type"] as? String != "active" {activeTurnID=""}
                    return working && activeTurnID.isEmpty && probeGeneration == nil ? [beginProbe()] : []
                }
                if method == "turn/completed",params["threadId"] as? String == threadID,let turn=(params["turn"] as? Row)?["id"] as? String {
                    turnGeneration += 1
                    if activeTurnID == turn {activeTurnID="";working=false}
                    soliciting=soliciting.filter{$0.value != turn && !$0.value.isEmpty}
                    guard retiredTurns.count < 1024 || retiredTurns.contains(turn) else {throw HUDError("Codex approval connection reached its history limit. Reconnect to continue.")}
                    retiredTurns.insert(turn)
                    for id in order.filter({cards[$0]?.turnID == turn}) {try retire(id)}
                    return []
                }
                if method == "thread/started", let thread=params["thread"] as? Row, let id=thread["id"] as? String, id != threadID {
                    throw HUDError("Terminal changed chats. Use its terminal for approvals.")
                }
                if method == "serverRequest/resolved", params["threadId"] as? String == threadID, let id=WireID(params["requestId"]) {
                    soliciting.removeValue(forKey:id);try retire(id);return []
                }
                if ["mcpServer/elicitation/request","item/tool/requestUserInput","item/permissions/requestApproval","item/commandExecution/requestApproval","item/fileChange/requestApproval"].contains(method),params["threadId"] as? String == threadID,let id=WireID(row["id"]),!resolved.contains(id) {
                    guard soliciting.count<32 || soliciting[id] != nil else{throw HUDError("Too many Codex requests. Reconnect to continue.")}
                    soliciting[id]=params["turnId"] as? String ?? ""
                    if activeTurnID.isEmpty,let turn=params["turnId"] as? String,!turn.isEmpty,turn.utf8.count<=512,!retiredTurns.contains(turn){activeTurnID=turn}
                }
                guard method == "mcpServer/elicitation/request", params["threadId"] as? String == threadID,
                      let id=WireID(row["id"]) else { return [] }
                if resolved.contains(id) || (params["turnId"] as? String).map({retiredTurns.contains($0)}) == true{return []}
                let original=try JSONSerialization.data(withJSONObject:row,options:[.sortedKeys])
                if let old=cards[id] { guard old.original == original else { throw HUDError("This Codex approval changed. Use its terminal to continue.") };return [] }
                guard let card=try makeCard(id,params,original) else { return [] }
                guard cards.count < 16 else { throw HUDError("Too many Codex approvals. Use its terminal to continue.") }
                cards[id]=card;order.append(id);return []
            }
            if let pending=steerPending,row["id"] as? String == pending.rpcID {
                // A generic RPC error is not proof that the server accepted no input.
                // Only local preflight refusals are currently classified as certain.
                if row["error"] == nil,let result=row["result"] as? Row,result["turnId"] as? String == pending.turnID {
                    steerOutcome=["ok":true,"turnId":pending.turnID,"clientUserMessageId":pending.clientID,"uncertain":false]
                }else{
                    steerUncertain=true;steerOutcome=["error":"Follow-up delivery uncertain. Inspect this Codex chat before sending again.","uncertain":true]
                }
                steerPending=nil;return []
            }
            if let expected=probeID,row["id"] as? String == expected,let generation=probeGeneration {
                probeGeneration=nil;probeID=nil
                guard generation == turnGeneration else{return working && activeTurnID.isEmpty ? [beginProbe()] : []}
                if row["error"] == nil,let result=row["result"] as? Row,let rows=result["data"] as? [Row],rows.count<=1,
                   let turn=rows.first,turn["status"] as? String == "inProgress",let id=turn["id"] as? String,!id.isEmpty,id.utf8.count<=512,!retiredTurns.contains(id) {
                    activeTurnID=id
                }else if row["error"] == nil,let result=row["result"] as? Row,let rows=result["data"] as? [Row],rows.count==1,let turn=rows.first,
                         ["completed","failed","interrupted"].contains(turn["status"] as? String ?? ""),let id=turn["id"] as? String,!id.isEmpty,retiredTurns.count<1024 {
                    retiredTurns.insert(id)
                }
                return []
            }
            guard let id=row["id"] as? String, id == "hud-"+epoch+"-"+phase+(cycle == 0 ? "":"-"+String(cycle)), phase != "ready" else { return [] }
            if phase == "resume",let error=row["error"] as? Row,error["code"] as? Int == -32600,
               let message=error["message"] as? String,message == "no rollout found for thread id "+threadID,cards.isEmpty {
                phase="waiting";return []
            }
            if phase == "resume",let error=row["error"] as? Row,error["code"] as? Int == -32601,
               error["message"] as? String == "list_turns is not supported yet" {
                throw HUDError("Codex chat history is not ready. Wait for its first prompt to start, then reconnect.")
            }
            guard row["error"] == nil, let result=row["result"] as? Row else { throw HUDError("Codex approval connection was refused. Use its terminal to continue.") }
            switch phase {
            case "initialize": phase="loaded";return [["method":"initialized"],request("loaded","thread/loaded/list",[:])]
            case "loaded":
                guard let ids=result["data"] as? [String], ids == [threadID],
                      result["nextCursor"] == nil || result["nextCursor"] is NSNull else { throw HUDError("This Codex chat is not running on the selected server.") }
                phase="resume";return [request("resume","thread/resume",["threadId":threadID,"excludeTurns":true])]
            case "resume":
                guard (result["thread"] as? Row)?["id"] as? String == threadID else { throw HUDError("Codex returned a different chat. Use its terminal to continue.") }
                let thread=result["thread"] as! Row
                let status=thread["status"] as? Row ?? [:]
                working=status["type"] as? String == "active" && (status["activeFlags"] as? [String]) == []
                updateModel(result,effortKey:"reasoningEffort")
                phase="ready";return [beginProbe()]
            default:return []
            }
        }
        private mutating func updateModel(_ fields:Row,effortKey:String) {
            let reportedModel = fields["model"] as? String ?? ""
            model = reportedModel.range(of:"^[A-Za-z0-9][A-Za-z0-9._/:-]{0,119}$",options:.regularExpression) != nil ? reportedModel : ""
            let effort = fields[effortKey] as? String ?? ""
            reasoningEffort = ["none","minimal","low","medium","high","xhigh","max","ultra"].contains(effort) ? effort : ""
        }
        private mutating func beginProbe()->Row {
            probeGeneration=turnGeneration;let id="hud-"+epoch+"-turnprobe-"+UUID().uuidString;probeID=id
            return ["id":id,"method":"thread/turns/list","params":["threadId":threadID,"limit":1,"itemsView":"notLoaded","sortDirection":"desc"]]
        }
        mutating func prepareSteer(expectedTurnID:String,input:[Row],clientID:String,now:TimeInterval=ProcessInfo.processInfo.systemUptime)throws->Row {
            guard canSteer,expectedTurnID == activeTurnID else{throw HUDError("The active Codex turn changed or needs input. Your draft is retained.")}
            steerSequence += 1
            let id="hud-"+epoch+"-steer-"+String(steerSequence)
            steerPending=PendingSteer(rpcID:id,turnID:activeTurnID,clientID:clientID,started:now)
            return ["id":id,"method":"turn/steer","params":["threadId":threadID,"expectedTurnId":activeTurnID,"input":input,"clientUserMessageId":clientID]]
        }
        mutating func retryWaiting()->Row? {
            guard phase == "waiting" else{return nil}
            cycle += 1;phase="loaded"
            return request("loaded","thread/loaded/list",[:])
        }
        private mutating func retire(_ id:WireID)throws {
            guard resolved.count < 1024 || resolved.contains(id) else {throw HUDError("Codex approval connection reached its history limit. Reconnect to continue.")}
            resolved.insert(id);cards.removeValue(forKey:id);order.removeAll{$0 == id}
        }
        private static func explicitFalse(_ value:Any?)->Bool {
            guard let number=value as? NSNumber,CFGetTypeID(number)==CFBooleanGetTypeID() else{return false};return !number.boolValue
        }
        private func makeCard(_ id:WireID,_ params:Row,_ original:Data) throws -> Card? {
            // Only the exact message-only MCP tool-approval contract is supported.
            guard params["mode"] as? String == "form", let meta=params["_meta"] as? Row,
                  meta["codex_approval_kind"] as? String == "mcp_tool_call",
                  (meta["codex_requires_user_input"] == nil || Self.explicitFalse(meta["codex_requires_user_input"])),
                  let schema=params["requestedSchema"] as? Row, schema["type"] as? String == "object",
                  Set(schema.keys).isSubset(of:["type","properties","required","additionalProperties"]),
                  (schema["properties"] == nil || (schema["properties"] as? Row)?.isEmpty == true),
                  (schema["required"] == nil || (schema["required"] as? [Any])?.isEmpty == true),
                  (schema["additionalProperties"] == nil || Self.explicitFalse(schema["additionalProperties"])),
                  let turn=params["turnId"] as? String, !turn.isEmpty, turn.utf8.count <= 512,
                  let question=params["message"] as? String, !question.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,
                  question.utf8.count <= 32_768, let server=params["serverName"] as? String, !server.isEmpty, server.utf8.count <= 256 else { return nil }
            // Verification/checkpoint forms must remain with their native client.
            if meta.keys.contains(where:{ key in let compact=key.lowercased().filter{$0.isLetter || $0.isNumber};return compact.contains("verification") || compact.contains("humancommand") || compact.contains("humanapproval") }) { return nil }
            var details:Row=[:]
            for key in ["tool_name","tool_title","tool_description","tool_params","tool_params_display"] { if let value=meta[key] { details[key]=value } }
            let detailData=try JSONSerialization.data(withJSONObject:details,options:[.sortedKeys,.prettyPrinted])
            guard detailData.count <= 65_536 else { return nil }
            var choices:[Row]=[["key":"once","label":"Allow"]]
            let modes=(meta["persist"] as? [String]) ?? (meta["persist"] as? String).map{[$0]} ?? []
            if modes.contains("session") { choices.append(["key":"session","label":"Allow for this session"]) }
            if modes.contains("always") { choices.append(["key":"always","label":"Always allow"]) }
            choices.append(["key":"cancel","label":"Cancel"])
            return Card(id:id,token:epoch+":"+UUID().uuidString,original:original,question:question,detail:server+"\n"+String(decoding:detailData,as:UTF8.self),choices:choices,turnID:turn)
        }
        mutating func respond(token:String,choice:String,now:TimeInterval=ProcessInfo.processInfo.systemUptime) throws -> Row {
            guard connected, let id=order.first(where:{cards[$0]?.token == token}), var card=cards[id], card.sentAt == nil,
                  card.choices.contains(where:{$0["key"] as? String == choice}) else { throw HUDError("This approval changed or was already answered. Review the current Codex request.") }
            let meta:Any
            if choice == "session" || choice == "always" { meta=["persist":choice] }
            else if choice == "cancel" { meta=["codex_approval_cancellation_reason":"user"] }
            else { meta=NSNull() }
            card.sentAt=now;cards[id]=card
            return ["id":id.json,"result":["action":choice == "cancel" ? "cancel" : "accept","content":NSNull(),"_meta":meta]]
        }
    }
    /// Copies stay available through the steered turn; unknown outcomes are retained.
    /// The on-disk cap also counts files left by a prior interrupted HUD run.
    final class ImageCache {
        static let shared=ImageCache()
        let directory:URL
        private let lock=NSLock()
        private var accepted:[String:[String:[URL]]]=[:]
        init(directory:URL?=nil){self.directory=directory ?? FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("Herdr HUD/Followup Images",isDirectory:true)}
        private func folder()throws->Int32 {
            var fd=open("/",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC)
            guard fd>=0 else{throw HUDError("Cannot prepare follow-up images.")}
            for component in directory.pathComponents where component != "/" {
                guard component != ".",component != ".." else{close(fd);throw HUDError("Invalid image cache path.")}
                var next=openat(fd,component,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC)
                if next<0 && errno==ENOENT {guard mkdirat(fd,component,0o700)==0 || errno==EEXIST else{close(fd);throw HUDError("Cannot prepare follow-up images.")};next=openat(fd,component,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC)}
                close(fd);guard next>=0 else{throw HUDError("Cannot prepare follow-up images.")};fd=next
            }
            var info=stat();guard fstat(fd,&info)==0,info.st_uid==geteuid(),fchmod(fd,0o700)==0 else{close(fd);throw HUDError("Follow-up image cache is not private.")};return fd
        }
        func stage(_ images:[ImageAttachment])throws->[URL] {
            if images.isEmpty{return []}
            lock.lock();defer{lock.unlock()}
            let validated=try ImageAttachment.parse(images.map{["data":$0.data.base64EncodedString()]})
            let fd=try folder();defer{close(fd)}
            var total=0
            let existing=try FileManager.default.contentsOfDirectory(atPath:directory.path)
            guard existing.count+validated.count<=128 else{throw HUDError("Follow-up image cache is full. Queue this prompt or inspect earlier deliveries.")}
            for name in existing {
                var info=stat()
                guard fstatat(fd,name,&info,AT_SYMLINK_NOFOLLOW)==0,(info.st_mode&S_IFMT)==S_IFREG,info.st_uid==geteuid(),info.st_nlink==1,info.st_size>=0,info.st_size<=ImageAttachment.maximumBytes else{throw HUDError("Follow-up image cache requires inspection before adding images.")}
                total += Int(info.st_size)
            }
            guard total+validated.reduce(0,{$0+$1.data.count})<=24*1024*1024 else{throw HUDError("Follow-up images total 24 MB. Queue this prompt or inspect earlier uncertain deliveries.")}
            var paths:[URL]=[]
            do {
                for image in validated {
                    let name="native-"+UUID().uuidString+"."+URL(fileURLWithPath:image.name).pathExtension
                    let file=openat(fd,name,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0o600)
                    guard file>=0 else{throw HUDError("Cannot save a follow-up image.")}
                    let path=directory.appendingPathComponent(name);paths.append(path)
                    do {
                        guard fchmod(file,0o600)==0 else{throw HUDError("Cannot protect a follow-up image.")}
                        try image.data.withUnsafeBytes{bytes in
                            var offset=0
                            while offset<bytes.count {
                                let count=Darwin.write(file,bytes.baseAddress!.advanced(by:offset),bytes.count-offset)
                                if count<0 && errno==EINTR{continue}
                                guard count>0 else{throw HUDError("Cannot save a follow-up image.")};offset += count
                            }
                        }
                        close(file)
                    }catch{close(file);throw error}
                }
                return paths
            }catch{for path in paths{unlinkat(fd,path.lastPathComponent,0)};throw error}
        }
        func accept(thread:String,turn:String,paths:[URL]) {
            guard !paths.isEmpty else{return};lock.lock();accepted[thread,default:[:]][turn,default:[]] += paths;lock.unlock()
        }
        func releaseCompleted(thread:String,turns:Set<String>) {
            lock.lock();var paths:[URL]=[]
            for turn in turns{paths += accepted[thread]?.removeValue(forKey:turn) ?? []}
            if accepted[thread]?.isEmpty == true{accepted.removeValue(forKey:thread)}
            lock.unlock();remove(paths)
        }
        func remove(_ paths:[URL]) {
            guard !paths.isEmpty else{return};lock.lock();defer{lock.unlock()}
            guard let fd=try? folder() else{return};defer{close(fd)}
            for path in paths where path.deletingLastPathComponent().path==directory.path && path.lastPathComponent.hasPrefix("native-"){unlinkat(fd,path.lastPathComponent,0)}
        }
    }
    private struct SteerOperation {let turnID:String,files:[URL],completion:(Row)->Void}
    private final class Session {
        var state:ProtocolState, outbound:[Row]=[], cancelled=false
        var steerOperation:SteerOperation?
        init(threadID:String){state=ProtocolState(threadID:threadID)}
    }
    private let socketPath:String,threadID:String,onChange:(Row)->Void,imageCache:ImageCache
    private let lock=NSLock(),worker=DispatchQueue(label:"org.herdr.hud.codex-approvals")
    private var session:Session?
    private var uncertainSteer=false
    private var publication:(Row,Session?)?,publicationScheduled=false
    init(binary:String,socket:String,threadID:String,imageCache:ImageCache = .shared,initialSteerUncertain:Bool=false,onChange:@escaping(Row)->Void){socketPath=socket;self.threadID=threadID;self.onChange=onChange;self.imageCache=imageCache;uncertainSteer=initialSteerUncertain}
    func connect(){
        lock.lock();if session != nil {lock.unlock();return};let current=Session(threadID:threadID);current.state.steerUncertain=uncertainSteer;session=current;lock.unlock()
        publish(current.state.snapshot,current)
        worker.async{[weak self] in self?.run(current)}
    }
    func disconnect(){
        lock.lock();let pending=session?.steerOperation;if pending != nil{uncertainSteer=true};session?.steerOperation=nil;session?.cancelled=true;session=nil;lock.unlock()
        if let pending{complete(pending,["error":"Follow-up delivery uncertain after disconnect. Inspect this Codex chat before sending again.","uncertain":true])}
        publish(["connected":false,"status":"Codex approvals disconnected.","cards":[Row](),"threadId":threadID,"canSteer":false,"activeTurnId":"","steerUncertain":uncertainSteer],nil)
    }
    func reconcileSteer()throws {
        lock.lock();defer{lock.unlock()}
        guard let current=session,current.state.connected,current.state.steerPending == nil,current.steerOperation == nil else{throw HUDError("Reconnect to this Codex chat and inspect it before enabling another follow-up.")}
        uncertainSteer=false;current.state.steerUncertain=false
        let snapshot=current.state.snapshot
        DispatchQueue.main.async{[weak self,weak current] in guard let self,let current else{return};self.publish(snapshot,current)}
    }
    func steer(expectedTurnID:String,text:String,attachments:[ImageAttachment],completion:@escaping(Row)->Void)throws {
        guard text.utf8.count<=60_000,!text.contains("\0"),!text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || !attachments.isEmpty else{throw HUDError("Enter a follow-up under 60 KB or attach images.")}
        lock.lock();let current=session;let valid=current?.state.canSteer == true && current?.state.activeTurnID==expectedTurnID;lock.unlock()
        guard valid,let current else{throw HUDError("The active Codex turn changed or needs input. Your draft is retained.")}
        let files=try imageCache.stage(attachments)
        var input:[Row]=[]
        if !text.isEmpty{input.append(["type":"text","text":text])}
        input.append(contentsOf:files.map{["type":"localImage","path":$0.path]})
        lock.lock()
        do {
            guard session === current,!current.cancelled,current.outbound.count<16 else{throw HUDError("Codex follow-up connection changed. Your draft is retained.")}
            let row=try current.state.prepareSteer(expectedTurnID:expectedTurnID,input:input,clientID:UUID().uuidString)
            current.steerOperation=SteerOperation(turnID:expectedTurnID,files:files,completion:completion)
            current.outbound.append(row);let snapshot=current.state.snapshot;lock.unlock();publish(snapshot,current)
        }catch{lock.unlock();imageCache.remove(files);throw error}
    }
    private func complete(_ operation:SteerOperation,_ result:Row){DispatchQueue.main.async{operation.completion(result)}}
    func respond(token:String,choice:String) throws {
        lock.lock()
        do {
            guard let current=session,!current.cancelled else {throw HUDError("Codex approval connection is closed.")}
            guard current.outbound.count < 16 else {throw HUDError("Codex approval connection is busy. Check its terminal.")}
            let row=try current.state.respond(token:token,choice:choice)
            current.outbound.append(row);let snapshot=current.state.snapshot;lock.unlock();publish(snapshot,current)
        } catch {lock.unlock();throw error}
    }
    private func publish(_ value:Row,_ current:Session?){
        lock.lock()
        let valid=current.map{session === $0 && !$0.cancelled} ?? (session == nil)
        guard valid else{lock.unlock();return}
        publication=(value,current)
        if publicationScheduled{lock.unlock();return}
        publicationScheduled=true;lock.unlock()
        DispatchQueue.main.async{[weak self] in
            guard let self else{return};self.lock.lock()
            let publication=self.publication;self.publication=nil;self.publicationScheduled=false
            let valid=publication.map{entry in entry.1.map{self.session === $0 && !$0.cancelled} ?? (self.session == nil)} ?? false
            self.lock.unlock()
            if valid,let publication{self.onChange(publication.0)}
        }
    }
    private func run(_ current:Session){
        do {try transport(current)}
        catch {
            lock.lock();guard session === current else{lock.unlock();return};let pending=current.steerOperation;if pending != nil{uncertainSteer=true};current.steerOperation=nil;current.cancelled=true;session=nil;lock.unlock()
            if let pending{complete(pending,["error":"Follow-up delivery uncertain. Inspect this Codex chat before sending again.","uncertain":true])}
            let status=(error as? HUDError)?.message ?? "Codex approval connection lost. Delivery may be uncertain; inspect its terminal."
            publish(["connected":false,"status":status,"cards":[Row](),"threadId":threadID,"canSteer":false,"activeTurnId":"","steerUncertain":uncertainSteer],nil)
        }
    }
    private func transport(_ current:Session)throws {
        // The native helper speaks WebSocket over the dedicated Unix socket.
        // The stock `app-server proxy` is a raw-byte tunnel, not a JSONL adapter.
        let socket=try CodexSocket(path:socketPath);defer{socket.close()}
        try socket.send(current.state.begin())
        var handshakeDeadline=ProcessInfo.processInfo.systemUptime+15
        var waitingSince:TimeInterval?
        var lastSnapshot=Data()
        while true {
            lock.lock()
            let cancelled=current.cancelled || session !== current,ready=current.state.connected
            let waiting=current.state.phase == "waiting"
            if waiting {
                if waitingSince == nil{waitingSince=ProcessInfo.processInfo.systemUptime}
                if ProcessInfo.processInfo.systemUptime-waitingSince! >= 2,let retry=current.state.retryWaiting(){
                    current.outbound.append(retry);waitingSince=nil;handshakeDeadline=ProcessInfo.processInfo.systemUptime+15
                }
            }
            let expired=current.state.cards.values.contains{$0.sentAt.map{ProcessInfo.processInfo.systemUptime-$0>75} ?? false} || current.state.steerPending.map{ProcessInfo.processInfo.systemUptime-$0.started>15} == true
            let outgoing=current.outbound;current.outbound.removeAll();lock.unlock()
            if cancelled{return}
            guard (ready || waiting || ProcessInfo.processInfo.systemUptime<handshakeDeadline),!expired else{throw HUDError("Codex approval connection timed out. Delivery may be uncertain; inspect its terminal.")}
            for message in outgoing{try socket.send(message)}
            guard let row=try socket.receive(timeout:0.2) else{continue}
            lock.lock()
            do {
                let oldPhase=current.state.phase
                let messages=try current.state.receive(row)
                if current.state.phase != oldPhase && current.state.phase != "waiting" {handshakeDeadline=ProcessInfo.processInfo.systemUptime+15}
                guard current.outbound.count+messages.count <= 16 else{throw HUDError("Codex approval connection queue exceeded its limit.")}
                current.outbound.append(contentsOf:messages)
                var completed:SteerOperation?,outcome:Row?,remove:[URL]=[]
                if let result=current.state.steerOutcome,let operation=current.steerOperation {
                    current.state.steerOutcome=nil;current.steerOperation=nil;completed=operation;outcome=result
                    if result["uncertain"] as? Bool == true{uncertainSteer=true}
                    if result["ok"] as? Bool == true {
                        if current.state.retiredTurns.contains(operation.turnID){remove += operation.files}
                        else{imageCache.accept(thread:threadID,turn:operation.turnID,paths:operation.files)}
                    }else if result["uncertain"] as? Bool == false {remove += operation.files}
                }
                let snapshot=current.state.snapshot,completedTurns=current.state.retiredTurns
                let encoded=try JSONSerialization.data(withJSONObject:snapshot,options:[.sortedKeys])
                lock.unlock()
                imageCache.remove(remove)
                imageCache.releaseCompleted(thread:threadID,turns:completedTurns)
                if let completed,let outcome{complete(completed,outcome)}
                if encoded != lastSnapshot{lastSnapshot=encoded;publish(snapshot,current)}
            }catch{lock.unlock();throw error}
        }
    }
}
