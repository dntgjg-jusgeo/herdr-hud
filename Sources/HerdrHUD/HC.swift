import Foundation
import CoreFoundation

/// hc owns machine routing. Never reinterpret a saved --via command as an SSH target.
final class HCClient {
    let binary: String
    let execute: (Invocation) throws -> String
    var cache: [String: [Row]] = [:]
    var bindings: [String: Row] = [:]
    var lastMachines: [Row] = []
    init(binary: String, execute: @escaping (Invocation) throws -> String) {
        self.binary = binary; self.execute = execute
    }
    func rpc(_ requests: [(String, Row)], mutation: Bool = false) throws -> [Row] {
        let ids = requests.map { _ in UUID().uuidString }
        let wire = zip(ids, requests).map { id, request in
            encode(["jsonrpc":"2.0", "id":id, "method":request.0, "params":request.1])
        }.joined(separator:"\n") + "\n"
        let raw = try execute(Invocation(executable:binary, arguments:["connect", "--session", "default"], mutation:mutation, input:Data(wire.utf8), responseIDs:Set(ids)))
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
        return (id,replies[1],machines)
    }
    static func provider(_ terminal: Row) -> String? {
        guard let foreground = terminal["foreground"] as? Row, let args = foreground["argv"] as? [String] else { return nil }
        // A provider token in a task argument is not executable identity.
        let executable = args.first.map { URL(fileURLWithPath:$0).lastPathComponent.lowercased() } ?? ""
        var entry = executable
        if ["node", "nodejs"].contains(executable), args.count > 1, !args[1].hasPrefix("-") {
            entry = URL(fileURLWithPath:args[1]).lastPathComponent.lowercased()
        }
        for provider in ["claude", "codex"] {
            if entry == provider || entry == provider + ".js" { return provider }
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
        let reportedByProvider = provider == "claude" ? ["claude", "claude-code"].contains(app) : app == "codex"
        let state = reportedByProvider ? status["state"] as? String ?? "unknown" : "unknown"
        let identity: Row = ["core":core,"remote":remoteIdentity,"created_ms":created,"pid":pid,"provider":provider,"app":app]
        let cwd = foreground["cwd"] as? String ?? terminal["cwd"] as? String ?? ""
        let location = labels["where"]?.components(separatedBy:" / ")
        let workspace = labels["workspace"] ?? location?.first ?? URL(fileURLWithPath:cwd).lastPathComponent
        let tab = location?.dropFirst().joined(separator:" / ") ?? terminal["title"] as? String ?? address
        let title = terminal["name"] as? String ?? labels["name"] ?? (tab + " · " + (provider == "claude" ? "Claude" : "Codex"))
        var row: Row = ["pane_id":address,"terminal_id":address,"agent_session":identity,"agent":provider,
                       "can_prompt":state == "idle",
                       "agent_status":["idle","working","done","blocked","error"].contains(state) ? state : "unknown",
                       "workspace_id":labels["herdr.space"] ?? cwd,"workspace_label":workspace,
                       "tab_id":labels["herdr.tab"] ?? address,"tab_label":title.isEmpty ? address : title,"name":title,
                       "machine_id":machineID,"machine_label":label,"online":true]
        if machineID == "local", cwd.hasPrefix("/") { row["preview_directory"] = cwd }
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
        return ["id":id,"provider":row["agent"]!,"text":text]
    }
    func prompt(_ id: String, _ text: String) throws -> Row {
        guard !text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty, text.utf8.count <= 60000, !text.contains("\0"), !text.hasPrefix("-") else { throw HUDError("Enter a prompt under 60 KB that does not start with a dash.") }
        let row = try resolve(id)
        // hc's atomic status condition only supports idle/working; done is displayed but
        // is deliberately read-only until the program reports idle.
        guard row["agent_status"] as? String == "idle" else { throw HUDError("This agent is busy or needs input. Answer native questions in Herdr.") }
        do {
            let result = try rpc([("terminal.send",["terminal":row["terminal_id"]!,"text":text,"if":"idle","force":false,"wait":false])],mutation:true)[0]
            guard let turn = result["turn"] as? NSNumber, CFGetTypeID(turn) != CFBooleanGetTypeID(), turn.doubleValue >= 0, turn.doubleValue.rounded(.down) == turn.doubleValue else { throw HUDError("Invalid hc acknowledgement.") }
            return ["ok":true,"id":id]
        } catch {
            throw HUDError("Delivery uncertain or refused. Inspect Herdr before sending again.")
        }
    }
}
