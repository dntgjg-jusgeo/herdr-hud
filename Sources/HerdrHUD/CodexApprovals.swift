import Foundation
import CoreFoundation
import Darwin

/// A second, request-ID-bound client of an already-running dedicated Codex server.
/// It never starts a daemon, starts a turn, changes settings, or sends terminal keys.
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
    struct Card {
        let id:WireID, token:String, original:Data, question:String, detail:String, choices:[Row], turnID:String
        var sentAt:TimeInterval?
        var row:Row { ["token":token,"question":question,"detail":detail,"choices":choices,"pending":sentAt != nil] }
    }
    /// Pure protocol state, independently tested without a live server or model.
    struct ProtocolState {
        let threadID:String, epoch:String
        var cycle=0
        var phase="initialize", cards:[WireID:Card]=[:], order:[WireID]=[], resolved=Set<WireID>(), retiredTurns=Set<String>()
        init(threadID:String,epoch:String=UUID().uuidString) { self.threadID=threadID;self.epoch=epoch }
        var connected:Bool { phase == "ready" }
        var snapshot:Row { ["connected":connected,"status":phase == "waiting" ? "Waiting for the first prompt in this new Codex chat." : connected ? "Connected to Codex approvals." : "Connecting to Codex approvals…","cards":connected ? order.compactMap{cards[$0]?.row} : [Row](),"threadId":threadID] }
        func request(_ stage:String,_ method:String,_ params:Row)->Row { ["id":"hud-"+epoch+"-"+stage+(cycle == 0 ? "":"-"+String(cycle)),"method":method,"params":params] }
        func begin()->Row { request("initialize","initialize",["clientInfo":["name":"herdr_hud","title":"Herdr HUD","version":"1"],"capabilities":["experimentalApi":true]]) }
        mutating func receive(_ row:Row) throws -> [Row] {
            if let method=row["method"] as? String {
                let params=row["params"] as? Row ?? [:]
                if ["thread/closed","thread/archived","thread/deleted"].contains(method),params["threadId"] as? String == threadID {
                    throw HUDError("This Codex chat closed. Use its terminal to continue.")
                }
                if method == "turn/completed",params["threadId"] as? String == threadID,let turn=(params["turn"] as? Row)?["id"] as? String {
                    guard retiredTurns.count < 1024 || retiredTurns.contains(turn) else {throw HUDError("Codex approval connection reached its history limit. Reconnect to continue.")}
                    retiredTurns.insert(turn)
                    for id in order.filter({cards[$0]?.turnID == turn}) {try retire(id)}
                    return []
                }
                if method == "thread/started", let thread=params["thread"] as? Row, let id=thread["id"] as? String, id != threadID {
                    throw HUDError("Terminal changed chats. Use its terminal for approvals.")
                }
                if method == "serverRequest/resolved", params["threadId"] as? String == threadID, let id=WireID(params["requestId"]) {
                    try retire(id);return []
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
                phase="ready";return []
            default:return []
            }
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
    private final class Session {
        var state:ProtocolState, outbound:[Row]=[], cancelled=false
        init(threadID:String){state=ProtocolState(threadID:threadID)}
    }
    private let socketPath:String,threadID:String,onChange:(Row)->Void
    private let lock=NSLock(),worker=DispatchQueue(label:"org.herdr.hud.codex-approvals")
    private var session:Session?
    private var publication:(Row,Session?)?,publicationScheduled=false
    init(binary:String,socket:String,threadID:String,onChange:@escaping(Row)->Void){socketPath=socket;self.threadID=threadID;self.onChange=onChange}
    func connect(){
        lock.lock();if session != nil {lock.unlock();return};let current=Session(threadID:threadID);session=current;lock.unlock()
        publish(current.state.snapshot,current)
        worker.async{[weak self] in self?.run(current)}
    }
    func disconnect(){
        lock.lock();session?.cancelled=true;session=nil;lock.unlock()
        publish(["connected":false,"status":"Codex approvals disconnected.","cards":[Row](),"threadId":threadID],nil)
    }
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
            lock.lock();guard session === current else{lock.unlock();return};current.cancelled=true;session=nil;lock.unlock()
            let status=(error as? HUDError)?.message ?? "Codex approval connection lost. Delivery may be uncertain; inspect its terminal."
            publish(["connected":false,"status":status,"cards":[Row](),"threadId":threadID],nil)
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
            let expired=current.state.cards.values.contains{$0.sentAt.map{ProcessInfo.processInfo.systemUptime-$0>75} ?? false}
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
                let snapshot=current.state.snapshot
                let encoded=try JSONSerialization.data(withJSONObject:snapshot,options:[.sortedKeys])
                lock.unlock()
                if encoded != lastSnapshot{lastSnapshot=encoded;publish(snapshot,current)}
            }catch{lock.unlock();throw error}
        }
    }
}
