import XCTest
@testable import HerdrHUD

/// Opt-in only. Starts and stops its own scratch core; never prompts user agents.
final class HCIntegrationTests: XCTestCase {
    func testIsolatedCoreDiscoveryOutputAndDelivery() throws {
        guard let binary = ProcessInfo.processInfo.environment["HUD_HC_INTEGRATION_BINARY"] else {
            throw XCTSkip("Set HUD_HC_INTEGRATION_BINARY to an installed hc to run the isolated integration test.")
        }
        let fm = FileManager.default
        let root = URL(fileURLWithPath:"/private/tmp/hhud-" + String(UUID().uuidString.prefix(8)))
        try fm.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? fm.removeItem(at:root) }
        let runner = ProcessRunner(timeout:20)
        func command(_ executable:String, _ args:[String]) throws -> String {
            try runner.run(Invocation(executable:executable,arguments:args,mutation:false))
        }
        func object(_ value:String) throws -> Row {
            try XCTUnwrap(JSONSerialization.jsonObject(with:Data(value.utf8)) as? Row)
        }
        // Capture only the real core's identity. It must differ before any fixture mutation.
        let real = try object(command(binary,["server","status","--json"]))
        let realID = try XCTUnwrap((real["core"] as? Row)?["id"] as? String)
        let wrapper = root.appendingPathComponent("hc")
        let session = "hud-fixture-" + String(UUID().uuidString.prefix(8)).lowercased()
        for folder in ["config","data","state","cache","runtime"] {
            try fm.createDirectory(at:root.appendingPathComponent(folder),withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        }
        let script = """
        #!/bin/sh
        export HC_SESSION=\(shellQuote(session))
        export HC_SOCKET=\(shellQuote(root.appendingPathComponent("core.sock").path))
        export XDG_CONFIG_HOME=\(shellQuote(root.appendingPathComponent("config").path))
        export XDG_DATA_HOME=\(shellQuote(root.appendingPathComponent("data").path))
        export XDG_STATE_HOME=\(shellQuote(root.appendingPathComponent("state").path))
        export XDG_CACHE_HOME=\(shellQuote(root.appendingPathComponent("cache").path))
        export XDG_RUNTIME_DIR=\(shellQuote(root.appendingPathComponent("runtime").path))
        if [ "$1" = connect ]; then
          shift
          if [ "$1" = --session ]; then shift 2; fi
          exec \(shellQuote(binary)) connect --session \(shellQuote(session)) "$@"
        fi
        exec \(shellQuote(binary)) "$@"
        """
        try script.write(to:wrapper,atomically:true,encoding:.utf8)
        try fm.setAttributes([.posixPermissions:0o700],ofItemAtPath:wrapper.path)
        _ = try command(wrapper.path,["server","start","--json"])
        let isolated = try object(command(wrapper.path,["server","status","--json"]))
        let isolatedID = try XCTUnwrap((isolated["core"] as? Row)?["id"] as? String)
        guard isolatedID != realID else { XCTFail("Fixture isolation failed; no terminals created or core stopped."); return }
        defer { _ = try? command(wrapper.path,["server","stop","--json"]) }
        let fixture = root.appendingPathComponent("fixture.c")
        let program = root.appendingPathComponent("codex")
        let fixtureCode = """
        #include <stdio.h>
        static void status(const char *state) {
            printf("\\033]7501;state=%s:app=codex\\007", state);
            fflush(stdout);
        }
        int main(void) {
            char line[1024];
            status("idle");
            puts("HUD_FIXTURE_READY"); fflush(stdout);
            while (fgets(line, sizeof(line), stdin)) {
                status("working");
                printf("HUD_FIXTURE_RECEIVED:%s", line); fflush(stdout);
                status("done");
            }
            return 0;
        }
        """
        try fixtureCode.write(to:fixture,atomically:true,encoding:.utf8)
        _ = try command("/usr/bin/clang",[fixture.path,"-o",program.path])
        _ = try command(wrapper.path,["run","--bg","--no-parent","--no-notify","--name","hud-fixture","--cwd",root.path,"--label","where=Fixture / Test","--",program.path])
        let client = HerdrClient(binary:wrapper.path)
        var rows:[Row] = []
        let readyBy = Date().addingTimeInterval(10)
        repeat {
            rows = client.snapshot()["agents"] as? [Row] ?? []
            if rows.count == 1 && rows[0]["agent_status"] as? String == "idle" { break }
            Thread.sleep(forTimeInterval:0.1)
        } while Date() < readyBy
        if rows.isEmpty {
            let facts = try object(command(wrapper.path,["get","hud-fixture","--json"]))
            let foreground = facts["foreground"] as? Row ?? [:]
            print("Fixture discovery diagnostic:", encode(["state":facts["state"] ?? NSNull(),"status":facts["status"] ?? NSNull(),"foregroundPID":foreground["pid"] ?? NSNull(),"snapshot":client.snapshot()]))
        }
        XCTAssertEqual(rows.count,1)
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row["agent_status"] as? String,"idle")
        let id = try XCTUnwrap(row["id"] as? String)
        let before = try client.output(id)["text"] as? String ?? ""
        XCTAssertTrue(before.contains("HUD_FIXTURE_READY"))
        XCTAssertEqual(try client.prompt(id,"isolated-delivery-proof")["ok"] as? Bool,true)
        let after = try client.output(id)["text"] as? String ?? ""
        XCTAssertTrue(after.contains("HUD_FIXTURE_RECEIVED:isolated-delivery-proof"))
        XCTAssertEqual(after.components(separatedBy:"HUD_FIXTURE_RECEIVED:isolated-delivery-proof").count - 1,1)
        let address = try XCTUnwrap(row["terminal_id"] as? String)
        let probe:Row = ["jsonrpc":"2.0","id":"fixture-done-probe","method":"terminal.send","params":["terminal":address,"text":"done-condition-probe","if":"idle","force":false,"wait":false]]
        let refused = try object(runner.run(Invocation(executable:wrapper.path,arguments:["connect"],mutation:true,input:Data((encode(probe)+"\n").utf8),responseIDs:["fixture-done-probe"])))
        let refusal = (refused["error"] as? Row)?["data"] as? Row
        XCTAssertEqual(refusal?["kind"] as? String,"status_mismatch")
        XCTAssertFalse((try client.output(id)["text"] as? String ?? "").contains("HUD_FIXTURE_RECEIVED:done-condition-probe"))
        let currentReal = try object(command(binary,["server","status","--json"]))
        XCTAssertEqual((currentReal["core"] as? Row)?["id"] as? String,realID)
        print("Isolated hc integration: discovered fixture, read output, delivered once; real core identity unchanged.")
    }
}
