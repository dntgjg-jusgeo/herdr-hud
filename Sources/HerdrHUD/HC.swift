import Foundation
import CoreFoundation

/// hc owns machine routing. Never reinterpret a saved --via command as an SSH target.
final class HCClient {
    let binary: String
    let execute: (Invocation) throws -> String
    var cache: [String: [Row]] = [:]
    var bindings: [String: Row] = [:]
    var lastMachines: [Row] = []
    var guardedFeature = false
    var guardedUncertainUntil: [String:Date] = [:]
    struct ChoicePreview { let token: String; let text: String; let date: Date; let choices: [Row] }
    var choicePreviews: [String:ChoicePreview] = [:]
    struct KeyPreview { let token: String; let text: String; let kind: String; let date: Date }
    var keyPreviews: [String: KeyPreview] = [:]
    var uncertainKeys: Set<String> = []
    init(binary: String, execute: @escaping (Invocation) throws -> String) {
        self.binary = binary; self.execute = execute
    }
    func rpc(_ requests: [(String, Row)], mutation: Bool = false) throws -> [Row] {
        let ids = requests.map { _ in UUID().uuidString }
        let wire = try zip(ids, requests).map { id, request in
            String(decoding:try JSONSerialization.data(withJSONObject:["jsonrpc":"2.0", "id":id, "method":request.0, "params":request.1],options:[.sortedKeys,.withoutEscapingSlashes]),as:UTF8.self)
        }.joined(separator:"\n") + "\n"
        let raw = try execute(Invocation(executable:binary, arguments:["connect", "--session", "default"], mutation:mutation, input:Data(wire.utf8), responseIDs:Set(ids), maximumInputBytes:requests.count == 1 && requests[0].0 == "terminal.put" ? 6 * 1024 * 1024 : 524288))
        var replies: [String: Row] = [:]
        for line in raw.split(separator:"\n") {
            guard let reply = try? JSONSerialization.jsonObject(with:Data(line.utf8)) as? Row,
                  reply["jsonrpc"] as? String == "2.0", let id = reply["id"] as? String,
                  ids.contains(id) else { continue }
            guard replies[id] == nil else { throw HUDError("hc returned duplicate acknowledgements.") }
            replies[id] = reply
        }
        return try ids.map { id in
            guard let reply = replies[id], reply["error"] == nil, let result = reply["result"] as? Row else {
                throw HUDError(mutation ? "Delivery uncertain or refused. Inspect Herdr before sending again." : "hc returned an unsupported or refused response.")
            }
            return result
        }
    }
    func facts(_ method: String, _ params: Row = [:]) throws -> (String, Row, [Row]) {
        let replies = try rpc([("hello",["generation":1,"framed":false]), (method,params), ("machine.list",[:])])
        guard let generation = replies[0]["generation"] as? NSNumber, CFGetTypeID(generation) != CFBooleanGetTypeID(), generation.intValue == 1, replies[0]["framed"] as? Bool == false,
              let core = replies[0]["core"] as? Row, let id = core["id"] as? String, !id.isEmpty,
              let machines = replies[2]["machines"] as? [Row] else { throw HUDError("Cannot identify the hc core or its machines.") }
        guardedFeature = (replies[0]["features"] as? [String] ?? []).contains("guarded_keys_v1")
        return (id,replies[1],machines)
    }
    static func provider(_ terminal: Row) -> String? {
        guard let foreground = terminal["foreground"] as? Row, let args = foreground["argv"] as? [String] else { return nil }
        // A provider token in a task argument is not executable identity.
        let executable = args.first.map { URL(fileURLWithPath:$0).lastPathComponent.lowercased() } ?? ""
        var entry = executable, entryIndex = 0
        if ["node", "nodejs"].contains(executable), args.count > 1, !args[1].hasPrefix("-") {
            entry = URL(fileURLWithPath:args[1]).lastPathComponent.lowercased();entryIndex = 1
        }
        for provider in ["claude", "codex", "opencode"] {
            if entry == provider || entry == provider + ".js" {
                if provider == "codex", args.count > entryIndex+1, ["app-server","remote-control","exec-server"].contains(args[entryIndex+1]) { return nil }
                if provider == "opencode", args.count > entryIndex+1, ["serve","service","api","run","acp","models","auth","debug","reload","plugin","session","stats","pair","upgrade","update","uninstall"].contains(args[entryIndex+1]) { return nil }
                return provider
            }
        }
        return nil
    }
    static func row(_ terminal: Row, core: String, machines: [Row]) throws -> Row? {
        guard terminal["state"] as? String == "live", let provider = provider(terminal) else { return nil }
        guard let address = terminal["address"] as? String, !address.isEmpty,
              let created = terminal["created_ms"] as? NSNumber,
              let foreground = terminal["foreground"] as? Row, let pid = foreground["pid"] as? NSNumber else { throw HUDError("hc returned incomplete terminal identity.") }
        let parts = address.split(separator:"/")
        guard parts.count == 1 || parts.count == 2 else { throw HUDError("hc returned an unsupported terminal address.") }
        var machineID = "local", label = Host.current().localizedName ?? "This Mac", remoteIdentity: Any = NSNull()
        if parts.count == 2 {
            guard let machine = machines.first(where: { $0["name"] as? String == String(parts[0]) }),
                  let remoteID = machine["id"] as? String, !remoteID.isEmpty,
                  let target = machine["target"] as? String, !target.isEmpty, machine["state"] as? String == "connected" else { return nil }
            machineID = remoteID; label = machine["name"] as? String ?? remoteID
            remoteIdentity = [remoteID, machine["target"] ?? NSNull(), machine["session"] ?? NSNull(), machine["via"] ?? false]
        }
        let labels = terminal["labels"] as? [String:String] ?? [:]
        let status = terminal["status"] as? Row ?? [:]
        let app = status["app"] as? String ?? ""
        // OpenCode has no verified OSC status producer. Only the managed native
        // adapter may enrich its rows after exact server/session verification.
        let reportedByProvider = provider == "claude" ? ["claude", "claude-code"].contains(app) : provider == "codex" && app == "codex"
        let state = reportedByProvider ? status["state"] as? String ?? "unknown" : "unknown"
        let identity: Row = ["core":core,"remote":remoteIdentity,"created_ms":created,"pid":pid,"provider":provider,"app":app]
        let cwd = foreground["cwd"] as? String ?? terminal["cwd"] as? String ?? ""
        let location = labels["where"]?.components(separatedBy:" / ")
        let workspace = labels["workspace"] ?? location?.first ?? URL(fileURLWithPath:cwd).lastPathComponent
        let tab = location?.dropFirst().joined(separator:" / ") ?? terminal["title"] as? String ?? address
        let title = terminal["name"] as? String ?? labels["name"] ?? (tab + " · " + (provider == "claude" ? "Claude" : provider == "codex" ? "Codex" : "OpenCode"))
        var row: Row = ["pane_id":address,"terminal_id":address,"agent_session":identity,"agent":provider,
                       "can_prompt":state == "idle", "can_attach":machineID == "local", "input_kind":status["kind"] as? String ?? "",
                       "agent_status":["idle","working","done","blocked","error"].contains(state) ? state : "unknown",
                       "workspace_id":labels["herdr.space"] ?? cwd,"workspace_label":workspace,
                       "tab_id":labels["herdr.tab"] ?? address,"tab_label":title.isEmpty ? address : title,"name":title,
                       "machine_id":machineID,"machine_label":label,"online":true]
        if machineID == "local", cwd.hasPrefix("/") { row["preview_directory"] = cwd }
        if reportedByProvider || (provider == "opencode" && app == "opencode") {
            row["reported_model"] = status["model"] as? String
            row["reported_reasoning_effort"] = status["reasoning_effort"] as? String
        }
        row["id"] = encode([core, address, identity])
        return row
    }
    func snapshot() -> Row {
        do {
            let (core,list,machines) = try facts("terminal.list")
            guard let terminals = list["terminals"] as? [Row] else { throw HUDError("hc returned an unsupported terminal list.") }
            var rows = try terminals.compactMap { try Self.row($0,core:core,machines:machines) }
            var states: [Row] = [["id":"local","label":Host.current().localizedName ?? "This Mac","online":true,"count":rows.filter { $0["machine_id"] as? String == "local" }.count]]
            for machine in machines {
                guard let id = machine["id"] as? String, let name = machine["name"] as? String else { throw HUDError("hc returned incomplete machine identity.") }
                let online = machine["state"] as? String == "connected"
                states.append(["id":id,"label":name,"online":online,"count":rows.filter { $0["machine_id"] as? String == id }.count,"error":online ? "" : "Machine is offline or needs login."])
                if !online { rows += (cache[id] ?? []).map { $0.merging(["online":false],uniquingKeysWith:{ _,b in b }) } }
            }
            let liveIDs = rows.filter { $0["online"] as? Bool == true }.map { $0["id"] as! String }
            guard Set(liveIDs).count == liveIDs.count else { throw HUDError("hc returned duplicate terminal identities.") }
            bindings = Dictionary(uniqueKeysWithValues:rows.filter { $0["online"] as? Bool == true }.map { ($0["id"] as! String,$0) })
            cache = Dictionary(grouping:rows,by: { $0["machine_id"] as! String })
            lastMachines = states
            return ["agents":rows,"machines":states,"discoveryError":""]
        } catch {
            bindings = [:]
            return ["agents":cache.values.flatMap { $0 }.map { $0.merging(["online":false],uniquingKeysWith:{ _,b in b }) },
                    "machines":lastMachines.map { $0.merging(["online":false],uniquingKeysWith:{ _,b in b }) },"discoveryError":error.localizedDescription]
        }
    }
    func resolve(_ id: String) throws -> Row {
        guard let expected = bindings[id], let address = expected["terminal_id"] as? String else { throw HUDError("Agent is offline or changed. Refresh and select it again.") }
        let (core,terminal,machines) = try facts("terminal.get",["terminal":address])
        guard let current = try Self.row(terminal,core:core,machines:machines), current["id"] as? String == id else { throw HUDError("The selected agent was replaced. Select its new session.") }
        return current
    }
    func output(_ id: String) throws -> Row {
        let row = try resolve(id)
        let reply = try rpc([("terminal.read",["terminal":row["terminal_id"]!,"lines":180])])[0]
        guard let text = reply["text"] as? String else { throw HUDError("hc returned unsupported terminal output.") }
        var output: Row = ["id":id,"provider":row["agent"]!,"text":text,"screenComplete":reply["complete"] as? Bool == true]
        if Self.acceptsKeys(row) {
            let screen = try liveScreen(row)
            let current = try resolve(id)
            if Self.acceptsKeys(current), current["input_kind"] as? String == row["input_kind"] as? String {
                let previous = keyPreviews[id]
                let preview = previous.flatMap { $0.text == screen && $0.kind == row["input_kind"] as? String && Date().timeIntervalSince($0.date) < 15 ? $0 : nil } ?? KeyPreview(token:UUID().uuidString,text:screen,kind:row["input_kind"] as! String,date:Date())
                keyPreviews[id] = preview
                output["terminalControl"] = ["token":preview.token,"text":screen,"uncertain":uncertainKeys.contains(id)]
                if guardedFeature, current["agent"] as? String == "codex",current["machine_id"] as? String == "local",
                   let snapshot=try? rpc([("terminal.input_snapshot",["terminal":current["terminal_id"]!])])[0], snapshot["complete"] as? Bool == true,
                   let token=snapshot["token"] as? String, let live=snapshot["text"] as? String,live==screen,
                   let terminal=snapshot["terminal"] as? Row,let core=snapshot["core_id"] as? String,
                   let exact=try Self.row(terminal,core:core,machines:[]),exact["id"] as? String==id,
                   let choices=ApprovalMenu.choices(live) {
                    choicePreviews[id]=ChoicePreview(token:token,text:live,date:Date(),choices:choices)
                    output["terminalControl"]=["token":preview.token,"text":live,"uncertain":uncertainKeys.contains(id),"choiceToken":token,"choices":choices]
                } else { choicePreviews.removeValue(forKey:id) }

            }
        }
        return output
    }
    static func acceptsKeys(_ row: Row) -> Bool {
        row["agent_status"] as? String == "blocked" && ["permission", "question"].contains(row["input_kind"] as? String ?? "")
    }
    func liveScreen(_ row: Row) throws -> String {
        let reply = try rpc([("terminal.read",["terminal":row["terminal_id"]!,"lines":0])])[0]
        guard reply["how"] as? String == "screen", reply["complete"] as? Bool == true, let text = reply["text"] as? String, !text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { throw HUDError("Cannot read the current terminal screen.") }
        return text
    }
    func terminalKey(_ id: String, token: String, key: String) throws -> Row {
        guard ["up","down","enter","esc"].contains(key) else { throw HUDError("Unsupported terminal key.") }
        guard !uncertainKeys.contains(id) else { throw HUDError("Key delivery uncertain. Check the terminal before enabling another key.") }
        guard let preview = keyPreviews[id], preview.token == token, Date().timeIntervalSince(preview.date) < 15 else { throw HUDError("Terminal preview changed or expired. Refresh before using a control.") }
        keyPreviews.removeValue(forKey:id) // Every click consumes its preview, even if a preflight fails.
        let row = try resolve(id)
        guard Self.acceptsKeys(row), row["input_kind"] as? String == preview.kind, try liveScreen(row) == preview.text else { throw HUDError("Terminal question changed. Refresh and review it before using a control.") }
        let current = try resolve(id)
        guard Self.acceptsKeys(current), current["input_kind"] as? String == preview.kind else { throw HUDError("Agent no longer needs this input. Refresh its output.") }
        // hc queues keys after quiet; no atomic screen predicate exists. This is an
        // explicit raw-key control, never a semantic approval or automatic retry.
        do {
            let result = try rpc([("terminal.keys",["terminal":current["terminal_id"]!,"keys":[key]])],mutation:true)[0]
            guard let turn = result["turn"] as? NSNumber, CFGetTypeID(turn) != CFBooleanGetTypeID(), turn.doubleValue >= 0, turn.doubleValue.rounded(.down) == turn.doubleValue else { throw HUDError("Invalid key acknowledgement.") }
            return ["id":id,"ok":true]
        } catch {
            uncertainKeys.insert(id)
            throw HUDError("Key delivery uncertain or refused. Inspect this agent in Herdr before enabling another key.")
        }
    }
    func approvalChoice(_ id: String, token: String, key: String) throws -> Row {
        guard guardedFeature,!uncertainKeys.contains(id),let preview=choicePreviews[id],preview.token==token,Date().timeIntervalSince(preview.date)<15,
              preview.choices.contains(where: { $0["key"] as? String == key }) else { throw HUDError("Approval changed or expired. Refresh and review the question.") }
        choicePreviews.removeValue(forKey:id);keyPreviews.removeValue(forKey:id)
        let row=try resolve(id)
        guard Self.acceptsKeys(row),row["machine_id"] as? String=="local" else { throw HUDError("Approval is no longer available.") }
        // Only the guarded endpoint is allowed here: never fall back to raw keys.
        do {
            let result=try rpc([("terminal.keys_checked",["terminal":row["terminal_id"]!,"token":token,"key":key])],mutation:true)[0]
            if result["outcome"] as? String == "rejected" { return ["id":id,"error":"Question changed before the key could be sent. No key was sent."] }
            guard result["outcome"] as? String == "written" else { throw HUDError("Choice delivery uncertain.") }
            return ["id":id,"ok":true]
        } catch { uncertainKeys.insert(id);guardedUncertainUntil[id]=Date(timeIntervalSinceNow:2);throw HUDError("Key delivery uncertain or refused. Wait a moment and check Herdr before trying again.") }
    }
    func reconcileTerminalKeys(_ id: String) throws {
        guard guardedUncertainUntil[id].map({ Date() >= $0 }) ?? true else { throw HUDError("Key delivery uncertain. Wait a moment before checking Herdr again.") }
        _ = try resolve(id)
        guardedUncertainUntil.removeValue(forKey:id);choicePreviews.removeValue(forKey:id)
        uncertainKeys.remove(id); keyPreviews.removeValue(forKey:id)
    }
    func prompt(_ id: String, _ text: String, attachments: [ImageAttachment] = []) throws -> Row {
        guard (!text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || !attachments.isEmpty), text.utf8.count <= 60000, !text.contains("\0"), !text.hasPrefix("-") else { throw HUDError("Enter a prompt under 60 KB that does not start with a dash.") }
        let row = try resolve(id)
        // hc's atomic status condition only supports idle/working; done is displayed but
        // is deliberately read-only until the program reports idle.
        guard row["agent_status"] as? String == "idle" else { throw HUDError("This agent is busy or needs input. Answer native questions in Herdr.") }
        guard attachments.count <= ImageAttachment.maximumCount, attachments.isEmpty || row["machine_id"] as? String == "local" else { throw HUDError("Image attachments require a local hc agent.") }
        var message = text
        do {
            var paths: [String] = []
            for image in attachments {
                let current = try resolve(id)
                guard current["agent_status"] as? String == "idle" else { throw HUDError("Agent is no longer idle.") }
                let uploaded = try rpc([("terminal.put",["terminal":current["terminal_id"]!,"name":image.name,"data":image.data.base64EncodedString()])],mutation:true)[0]
                guard let path = uploaded["path"] as? String, path.hasPrefix("/"), !path.contains("\0"), path.utf8.count <= 4096,
                      let count = uploaded["bytes"] as? NSNumber, CFGetTypeID(count) != CFBooleanGetTypeID(), count.intValue == image.data.count else { throw HUDError("Invalid image upload acknowledgement.") }
                paths.append(path)
            }
            if !paths.isEmpty {
                message += "\n\n[HUD attached images]\nInspect these local image files using your image viewing/read tool before answering. Each line is a JSON-quoted file path:\n" + paths.map { encode($0) }.joined(separator:"\n") + "\n[/HUD attached images]"
                let current = try resolve(id)
                guard current["agent_status"] as? String == "idle" else { throw HUDError("Agent is no longer idle.") }
            }
            guard message.utf8.count <= 60000 else { throw HUDError("Prompt and image references exceed 60 KB.") }
            let result = try rpc([("terminal.send",["terminal":row["terminal_id"]!,"text":message,"if":"idle","force":false,"wait":false])],mutation:true)[0]
            guard let turn = result["turn"] as? NSNumber, CFGetTypeID(turn) != CFBooleanGetTypeID(), turn.doubleValue >= 0, turn.doubleValue.rounded(.down) == turn.doubleValue else { throw HUDError("Invalid hc acknowledgement.") }
            return ["ok":true,"id":id]
        } catch {
            throw HUDError(attachments.isEmpty ? "Delivery uncertain or refused. Inspect Herdr before sending again." : "Image upload or delivery uncertain. Inspect Herdr before sending again; draft and images retained.")
        }
    }
}
