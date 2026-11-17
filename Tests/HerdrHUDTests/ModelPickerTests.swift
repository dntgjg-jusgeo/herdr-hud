import XCTest
@testable import HerdrHUD

final class ModelPickerTests: XCTestCase {
    let codexBlank = """
    › Ask Codex to do anything
      GPT-6.2-Sol default · /fixture
      ← for agents · ? for shortcuts
    """
    let codexStaged = """
    › /model  choose what model and reasoning effort to use
    › /model
      GPT-6.2-Sol default · /fixture
    """
    let codexModels = """
      Select Model and Effort
    › 1. GPT-6.2-Sol (current)  Fast, go-to model for coding and everyday work.
      2. GPT-6.2-Astra          Our most capable model for complex coding and professional work.
      3. GPT-6.1 Terra          Efficient model that excels at visual understanding and computer use.
    ↓
      enter select · esc back
    """
    let codexReasoning = """
      Select Reasoning Level for GPT-6.2-Astra
      1. Low (default)    Fast responses with lighter reasoning
    › 2. Medium           Balances speed and reasoning depth for everyday tasks
      3. High             Greater reasoning depth for complex problems
      4. Extra high       Extra high reasoning depth for complex problems
      5. More reasoning…  Max and Ultra consume usage limits faster
      enter default · s session · esc back
    """
    let codexAdvanced = """
      Advanced Reasoning
      ⚠ Consumes usage limits faster
    › 1. Max    Deeper reasoning for the most difficult tasks
      2. Ultra  Most intensive reasoning
      enter default · s session · esc back
    """
    let claudeBlank = """
    ─────────────────────────────────────────────
    ❯\u{a0}
    ─────────────────────────────────────────────
      ⏵⏵ auto mode on (shift+tab to cycle) · ← for agents
    """
    let claudeStaged = """
      ❯ /model                      Set the AI model for Claude Code (currently Opus 5.5)
        /code-review                Review the current diff
    ─────────────────────────────────────────────
    ❯\u{a0}/model
    ─────────────────────────────────────────────
      ⏵⏵ auto mode on (shift+tab to cycle)
    """
    let claudeModels = """
       Select model
       Switch between Claude models. Your pick becomes the default for new sessions. For other/previous model names, specify with --model.
         1. Default (recommended) ✔  Use the default model (currently Opus 5.5) · $4/$20 per Mtok
       ❯ 2. Opus                     Opus 5.5 · Best for everyday, complex tasks · $4/$20 per Mtok
         3. Fable                    Fable 5.2 · Most capable for your hardest and longest-running tasks · $8/$40 per Mtok
         4. Sonnet                   Sonnet 5.5 · Efficient for routine tasks · $2/$10 per Mtok
         5. Haiku                    Haiku 5.5 · Fastest for quick answers
       ◐ Medium effort (default) ←/→ to adjust
       Enter to set as default · s to use this session only · Esc to cancel
    """

    func fixture(_ provider: String = "codex", state: String = "idle", address: String = "t3") -> HCTests.Fixture {
        let fixture = HCTests.Fixture()
        fixture.terminals = [HCTests().terminal(state,address:address,provider:provider)]
        fixture.client.hc.modelPickerAllowsClaude = { _ in true }
        fixture.screenText = provider == "codex" ? codexBlank : claudeBlank
        return fixture
    }

    func state(_ fixture: HCTests.Fixture, id: String) throws -> Row {
        try XCTUnwrap(fixture.client.output(id)["modelPicker"] as? Row)
    }

    func menuToken(_ fixture: HCTests.Fixture, id: String) throws -> String {
        try XCTUnwrap((state(fixture,id:id)["menu"] as? Row)?["token"] as? String)
    }

    func focus(_ screen: String, from current: Int, to target: Int) -> String {
        screen.replacingOccurrences(of:"› \(current).",with:"  \(current).")
            .replacingOccurrences(of:"  \(target).",with:"› \(target).")
    }

    func keys(_ fixture: HCTests.Fixture) throws -> [[String]] {
        try fixture.mutations.map { invocation in
            let request = try XCTUnwrap(JSONSerialization.jsonObject(with:XCTUnwrap(invocation.input)) as? Row)
            XCTAssertEqual(request["method"] as? String,"terminal.keys")
            return try XCTUnwrap((request["params"] as? Row)?["keys"] as? [String])
        }
    }

    func testCapturedMenusMatchProviderAndUseSessionOnlyKeys() throws {
        let models = try XCTUnwrap(ModelPicker.menu(codexModels,provider:"codex"))
        XCTAssertEqual(models.choices.map(\.key),["1","2","3"])
        XCTAssertEqual(models.choices[1].label,"GPT-6.2-Astra")
        XCTAssertEqual(models.choices[1].row["detail"] as? String,"Our most capable model for complex coding and professional work.")
        XCTAssertEqual(models.applyKey,"enter")
        let effort = try XCTUnwrap(ModelPicker.menu(codexReasoning,provider:"codex"))
        XCTAssertEqual(effort.applyKey,"s")
        XCTAssertEqual(effort.choices.map(\.label),["Low (default)","Medium","High","Extra high","More reasoning…"])
        let advanced = try XCTUnwrap(ModelPicker.menu(codexAdvanced,provider:"codex"))
        XCTAssertEqual(advanced.choices.map(\.label),["Max","Ultra"])
        XCTAssertEqual(advanced.note,"⚠ Consumes usage limits faster")
        let claude = try XCTUnwrap(ModelPicker.menu(claudeModels,provider:"claude"))
        XCTAssertEqual(claude.applyKey,"s")
        XCTAssertEqual(claude.choices.map(\.label),["Default (recommended) ✔","Opus","Fable","Sonnet","Haiku"])
        XCTAssertEqual(claude.note,"◐ Medium effort (default) ←/→ to adjust")
        XCTAssertNil(ModelPicker.menu(claudeModels,provider:"codex"))
        XCTAssertNil(ModelPicker.menu(codexModels,provider:"claude"))
        XCTAssertNil(ModelPicker.menu(codexModels+"\nUnexpected dialog",provider:"codex"))
        XCTAssertNil(ModelPicker.menu(claudeModels.replacingOccurrences(of:"s to use this session only · ",with:""),provider:"claude"))
        let custom = claudeModels.replacingOccurrences(of:"Opus                     Opus 5.5",with:"Custom                   Another provider")
        XCTAssertNil(ModelPicker.menu(custom,provider:"claude")?.applyKey)
    }

    func testMenuRejoinsTerminalWrappedDescriptions() throws {
        let wrapped = codexModels.replacingOccurrences(of:"complex coding and professional work.",
                                                        with:"complex coding\n" + String(repeating:" ",count:29) + "and professional work.")
        let menu = try XCTUnwrap(ModelPicker.menu(wrapped,provider:"codex"))
        XCTAssertEqual(menu.choices[1].detail,"Our most capable model for complex coding and professional work.")
        XCTAssertTrue(menu.canRevealNext)
        XCTAssertFalse(menu.canRevealPrevious)
        XCTAssertFalse(menu.choices.last?.detail.contains("↓") ?? true)
    }

    func testStagedOpenClickModelAndEffortKeepPromptSeparate() throws {
        let f = fixture(), id = f.id(), hc = f.client.hc
        XCTAssertEqual(try state(f,id:id)["ready"] as? Bool,true)
        let highlighted = focus(codexModels,from:1,to:2)
        f.afterKeys = { keys in
            switch keys {
            case ["/","m","o","d","e","l"]: f.screenText = self.codexStaged
            case ["enter"]: f.screenText = f.screenText == self.codexStaged ? self.codexModels : self.codexReasoning
            case ["down"]: f.screenText = f.screenText == self.codexModels ? highlighted : self.focus(self.codexReasoning,from:2,to:3)
            case ["s"]: f.screenText = self.codexBlank
            default: XCTFail("Unexpected key")
            }
        }
        try hc.openModelPicker(id,stillSelected:{true})
        let model = try menuToken(f,id:id)
        XCTAssertEqual(try state(f,id:id)["pending"] as? Bool,false)
        XCTAssertThrowsError(try f.client.prompt(id,"queued fixture"))
        XCTAssertThrowsError(try hc.modelPickerKey(id,token:model,key:"2",stillSelected:{true}))
        try hc.modelPickerKey(id,token:menuToken(f,id:id),key:"focus:2",stillSelected:{true})
        XCTAssertThrowsError(try hc.modelPickerKey(id,token:model,key:"focus:2",stillSelected:{true}))
        XCTAssertEqual(f.screenText,codexReasoning)
        let reasoning = try menuToken(f,id:id)
        XCTAssertThrowsError(try hc.modelPickerKey(id,token:reasoning,key:"enter",stillSelected:{true}))
        try hc.modelPickerKey(id,token:menuToken(f,id:id),key:"focus:3",stillSelected:{true})
        XCTAssertEqual(try state(f,id:id)["ready"] as? Bool,true)
        XCTAssertEqual(try keys(f),[["/","m","o","d","e","l"],["enter"],["down"],["enter"],["down"],["s"]])
        XCTAssertEqual(try f.client.prompt(id,"fixture after picker")["ok"] as? Bool,true)
    }

    func testCodexPartialNavigationNeverAcceptsCurrentDefault() throws {
        let f = fixture(), id = f.id(), hc = f.client.hc
        f.screenText = codexModels
        let token = try menuToken(f,id:id)
        f.afterKeys = { _ in f.screenText = "Selection changed" }
        XCTAssertThrowsError(try hc.modelPickerKey(id,token:token,key:"focus:3",stillSelected:{true}))
        XCTAssertEqual(try keys(f),[["down"]])

        // When a model has only one effort, the first menu itself offers a
        // session-only shortcut. Enter would update the default in this stage.
        f.screenText = codexModels.replacingOccurrences(of:"enter select",with:"enter default · s session")
        let singleEffort = try menuToken(f,id:id)
        XCTAssertThrowsError(try hc.modelPickerKey(id,token:singleEffort,key:"enter",stillSelected:{true}))
        f.afterKeys = { _ in f.screenText = self.codexBlank }
        try hc.modelPickerKey(id,token:menuToken(f,id:id),key:"focus:1",stillSelected:{true})
        XCTAssertEqual(try keys(f),[["down"],["s"]])
    }

    func testCodexNestedReasoningAndBackNeverApplyADefault() throws {
        let f = fixture(), id = f.id(), hc = f.client.hc
        f.screenText = codexReasoning
        f.afterKeys = { key in
            switch key {
            case ["down"]:
                if f.screenText == self.codexAdvanced {
                    f.screenText = self.focus(self.codexAdvanced,from:1,to:2)
                } else if f.screenText.contains("› 2. Medium") {
                    f.screenText = self.focus(self.codexReasoning,from:2,to:3)
                } else if f.screenText.contains("› 3. High") {
                    f.screenText = self.focus(self.codexReasoning,from:2,to:4)
                } else {
                    f.screenText = self.focus(self.codexReasoning,from:2,to:5)
                        .replacingOccurrences(of:"enter default · s session",with:"enter select")
                }
            case ["enter"]: f.screenText = self.codexAdvanced
            case ["esc"]: f.screenText = self.codexReasoning
            case ["s"]: f.screenText = self.codexBlank
            default: XCTFail("Unexpected key")
            }
        }
        try hc.modelPickerKey(id,token:menuToken(f,id:id),key:"focus:5",stillSelected:{true})
        XCTAssertEqual(f.screenText,codexAdvanced)
        try hc.modelPickerKey(id,token:menuToken(f,id:id),key:"esc",stillSelected:{true})
        XCTAssertEqual(f.screenText,codexReasoning)
        try hc.modelPickerKey(id,token:menuToken(f,id:id),key:"focus:5",stillSelected:{true})
        try hc.modelPickerKey(id,token:menuToken(f,id:id),key:"focus:2",stillSelected:{true})
        XCTAssertEqual(try keys(f),[["down"],["down"],["down"],["enter"],["esc"],
                                    ["down"],["down"],["down"],["enter"],["down"],["s"]])
        XCTAssertEqual(try state(f,id:id)["ready"] as? Bool,true)
    }

    func testClaudeClickAppliesToTheCurrentSession() throws {
        let f = fixture("claude"), id = f.id(), hc = f.client.hc
        f.screenText = claudeModels
        f.afterKeys = { key in
            switch key {
            case ["down"]:
                f.screenText = self.claudeModels.replacingOccurrences(of:"❯ 2.",with:"  2.")
                    .replacingOccurrences(of:"  3.",with:"❯ 3.")
            case ["s"]: f.screenText = self.claudeBlank
            default: XCTFail("Unexpected key")
            }
        }
        try hc.modelPickerKey(id,token:menuToken(f,id:id),key:"focus:3",stillSelected:{true})
        XCTAssertEqual(try keys(f),[["down"],["s"]])
        XCTAssertEqual(try state(f,id:id)["ready"] as? Bool,true)
    }

    func testChangedScreenBetweenFocusAndApplyStopsBeforeSubmit() throws {
        let f = fixture(), id = f.id(), hc = f.client.hc
        f.screenText = codexModels
        f.afterKeys = { _ in
            f.screenText = self.focus(self.codexModels,from:1,to:2)
            f.afterRead = { f.screenText = "The terminal changed." }
        }
        XCTAssertThrowsError(try hc.modelPickerKey(id,token:menuToken(f,id:id),key:"focus:2",stillSelected:{true}))
        XCTAssertEqual(try keys(f),[["down"]])
    }

    func testAcknowledgedApplyWithoutVerifiedOutcomeHoldsPrompt() throws {
        let f = fixture(), id = f.id(), hc = f.client.hc
        f.screenText = codexReasoning
        XCTAssertThrowsError(try hc.modelPickerKey(id,token:menuToken(f,id:id),key:"focus:2",stillSelected:{true}))
        XCTAssertTrue(hc.modelPickerUncertain.contains(id))
        f.screenText = codexBlank
        XCTAssertThrowsError(try f.client.prompt(id,"fixture"))
        XCTAssertEqual(try keys(f),[["s"]])
    }

    func testScrollDisclosureRevealsHiddenRowsWithoutApplying() throws {
        let f = fixture(), id = f.id(), hc = f.client.hc
        f.screenText = codexModels
        f.afterKeys = { key in
            XCTAssertEqual(key,["down"])
            switch f.screenText {
            case self.codexModels: f.screenText = self.focus(self.codexModels,from:1,to:2)
            case self.focus(self.codexModels,from:1,to:2): f.screenText = self.focus(self.codexModels,from:1,to:3)
            default: f.screenText = """
                Select Model and Effort
                ↑
                  2. GPT-6.2-Astra  Our most capable model for complex coding and professional work.
                  3. GPT-6.1 Terra  Efficient model that excels at visual understanding and computer use.
                › 4. GPT-6.2-Luna   Lightweight model for straightforward work.
                enter select · esc back
                """
            }
        }
        let initial = try XCTUnwrap(state(f,id:id)["menu"] as? Row)
        XCTAssertEqual(initial["nextKey"] as? String,"reveal:down")
        XCTAssertNil(initial["previousKey"])
        try hc.modelPickerKey(id,token:menuToken(f,id:id),key:"reveal:down",stillSelected:{true})
        let shifted = try XCTUnwrap(state(f,id:id)["menu"] as? Row)
        XCTAssertEqual(shifted["previousKey"] as? String,"reveal:up")
        XCTAssertNil(shifted["nextKey"])
        XCTAssertEqual(try keys(f),[["down"],["down"],["down"]])
    }

    func testOpenDoesNotSubmitWhenStagedScreenOrSelectedChatChanges() throws {
        for scenario in ["draft","selection","replacement"] {
            let f = fixture(), id = f.id(), hc = f.client.hc
            var selected = true
            f.afterKeys = { _ in
                if scenario == "draft" { f.screenText = self.codexStaged.replacingOccurrences(of:"› /model\n",with:"› /model something\n") }
                else { f.screenText = self.codexStaged }
                if scenario == "selection" { selected = false }
                if scenario == "replacement" { f.terminals[0]["created_ms"] = 1001 }
            }
            XCTAssertThrowsError(try hc.openModelPicker(id,stillSelected:{selected}))
            XCTAssertEqual(try keys(f),[["/","m","o","d","e","l"]])
            XCTAssertTrue(hc.modelPickerUncertain.contains(id))
        }
    }

    func testKeysCheckExactScreenReadinessAndAcknowledgement() throws {
        for scenario in ["partial","replacement","stale","busy","missing ack","wrong scope"] {
            let f = fixture("claude"), id = f.id(), hc = f.client.hc
            f.screenText = claudeModels
            let token = try menuToken(f,id:id)
            if scenario == "partial" { f.screenComplete = false }
            if scenario == "replacement" { f.terminals[0]["created_ms"] = 279 }
            if scenario == "stale" { f.screenText += "\nScreen changed" }
            if scenario == "busy" { f.terminals[0]["status"] = ["app":"claude","state":"working"] }
            if scenario == "missing ack" { f.sendError = true }
            let key = scenario == "wrong scope" ? "enter" : "s"
            XCTAssertThrowsError(try hc.modelPickerKey(id,token:token,key:key,stillSelected:{true}))
            XCTAssertEqual(f.mutations.count,scenario == "missing ack" ? 1 : 0)
            XCTAssertThrowsError(try hc.modelPickerKey(id,token:token,key:"s",stillSelected:{true}))
            XCTAssertEqual(f.mutations.count,scenario == "missing ack" ? 1 : 0)
            if scenario == "missing ack" {
                XCTAssertThrowsError(try f.client.prompt(id,"fixture"))
                f.screenText = claudeBlank
                XCTAssertThrowsError(try hc.reconcileModelPicker(id,stillSelected:{true}))
                hc.modelPickerHolds[id] = Date(timeIntervalSinceNow:-3)
                try hc.reconcileModelPicker(id,stillSelected:{true})
                XCTAssertEqual(try state(f,id:id)["ready"] as? Bool,true)
            }
        }
    }

    func testLocalRoutingAndBlankComposerChecks() throws {
        let cloud = fixture("codex",address:"worker/t3")
        cloud.machines = [["id":"other","target":"fixture","name":"worker","state":"connected"]]
        let cloudID = cloud.id()
        XCTAssertNil(try cloud.client.output(cloudID)["modelPicker"])
        XCTAssertThrowsError(try cloud.client.hc.openModelPicker(cloudID,stillSelected:{true}))
        XCTAssertTrue(cloud.mutations.isEmpty)

        let router = fixture("claude"), routerID = router.id()
        router.client.hc.modelPickerAllowsClaude = { _ in false }
        XCTAssertNil(try router.client.output(routerID)["modelPicker"])
        XCTAssertThrowsError(try router.client.hc.openModelPicker(routerID,stillSelected:{true}))
        XCTAssertTrue(router.mutations.isEmpty)
        XCTAssertTrue(ModelPicker.stagedCommand(claudeStaged,provider:"claude"))
        XCTAssertFalse(ModelPicker.blankComposer(claudeStaged,provider:"claude"))
        XCTAssertFalse(ModelPicker.blankComposer(codexBlank.replacingOccurrences(of:"Ask Codex to do anything",with:"My unfinished draft"),provider:"codex"))
        XCTAssertFalse(ModelPicker.blankComposer(claudeBlank.replacingOccurrences(of:"❯",with:"❯ Existing draft"),provider:"claude"))

        func routes(_ value: String) -> Bool { ModelPicker.allowsClaudeEnvironment(Array(value.utf8)[...]) }
        XCTAssertTrue(routes("PATH=/fixture\0ANTHROPIC_BASE_URL=https://api.anthropic.com\0"))
        XCTAssertFalse(routes("PATH=/fixture\0ANTHROPIC_BASE_URL=https://api.orcarouter.ai\0"))
        XCTAssertFalse(routes("PATH=/fixture\0ANTHROPIC_MODEL=orcarouter/auto\0"))
        XCTAssertFalse(routes("PATH=/fixture\0CLAUDE_CODE_USE_BEDROCK=1\0"))
        XCTAssertTrue(routes("PATH=/fixture\0CLAUDE_CODE_USE_BEDROCK=0\0ANTHROPIC_MODEL=claude-sonnet-5-5\0"))
    }
}
