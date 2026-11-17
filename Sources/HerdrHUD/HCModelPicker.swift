import CoreFoundation
import Foundation

extension HCClient {
    static func modelPickerProvider(_ row: Row) -> String? {
        guard row["machine_id"] as? String == "local", let provider = row["agent"] as? String,
              ["codex","claude"].contains(provider) else { return nil }
        return provider
    }

    private func modelPickerAllowed(_ row: Row, provider: String) -> Bool {
        guard Self.modelPickerProvider(row) == provider else { return false }
        if provider == "codex" { return true }
        guard let identity = row["agent_session"] as? Row, let pid = identity["pid"] as? NSNumber else { return false }
        let model = row["reported_model"] as? String ?? ""
        return !model.lowercased().contains("orcarouter") && modelPickerAllowsClaude(pid.int32Value)
    }

    private static func modelPickerIdle(_ row: Row) -> Bool {
        row["agent_status"] as? String == "idle" && (row["input_kind"] as? String ?? "").isEmpty
    }

    func modelPickerState(_ id: String, row: Row) -> Row? {
        guard let provider = Self.modelPickerProvider(row) else { return nil }
        defer { if modelPickerHolds[id] == nil { modelPickerAwaiting.removeValue(forKey:id) } }
        let screen = try? liveScreen(row)
        let current = (try? resolve(id))
        let exactIdle = current.map(Self.modelPickerIdle) ?? false
        let allowed = current.map { modelPickerAllowed($0,provider:provider) } ?? false
        let menu = allowed ? screen.flatMap { ModelPicker.menu($0,provider:provider) } : nil
        let blank = exactIdle && (screen.map { ModelPicker.blankComposer($0,provider:provider) } ?? false)
        if menu != nil {
            modelPickerAwaiting.removeValue(forKey:id)
            if modelPickerHolds[id] == nil { modelPickerHolds[id] = Date() }
        }
        if let deadline = modelPickerAwaiting[id], Date() >= deadline {
            modelPickerUncertain.insert(id)
        }
        let uncertain = modelPickerUncertain.contains(id)
        if blank && !uncertain && modelPickerAwaiting[id] == nil {
            modelPickerHolds.removeValue(forKey:id)
        }
        let staged = allowed && (screen.map { ModelPicker.stagedCommand($0,provider:provider) } ?? false)
        let pending = modelPickerHolds[id] != nil || staged
        let cannotVerify = (pending && (!exactIdle || !allowed || (menu == nil && modelPickerAwaiting[id] == nil)))
        guard allowed || pending || uncertain else { return nil }
        var output: Row = ["ready":blank && allowed && !pending && !uncertain,"pending":pending,"uncertain":uncertain || cannotVerify]
        guard exactIdle, allowed, !uncertain, let screen = screen, let menu = menu else {
            modelPickerPreviews.removeValue(forKey:id)
            return output
        }
        let now = Date()
        let prior = modelPickerPreviews[id]
        let preview = prior.flatMap {
            $0.screen == screen && now.timeIntervalSince($0.date) < 15 ? $0 : nil
        } ?? ModelPickerPreview(token:UUID().uuidString,screen:screen,date:now)
        modelPickerPreviews[id] = preview
        var visible: Row = ["token":preview.token,"heading":menu.heading,"text":menu.text,"choices":menu.choices.map(\.row)]
        visible["applyKey"] = menu.applyKey
        visible["note"] = menu.note
        if menu.canRevealPrevious { visible["previousKey"] = "reveal:up" }
        if menu.canRevealNext { visible["nextKey"] = "reveal:down" }
        output["menu"] = visible
        output["pending"] = false
        return output
    }

    func openModelPicker(_ id: String, stillSelected: () -> Bool) throws {
        let row = try resolve(id)
        guard let provider = Self.modelPickerProvider(row), try modelPickerReady(id,provider:provider),
              !modelPickerUncertain.contains(id), modelPickerHolds[id] == nil, stillSelected() else {
            throw HUDError("Select an idle local chat with an empty terminal composer to open its model picker.")
        }
        modelPickerPreviews.removeValue(forKey:id)
        modelPickerHolds[id] = Date()
        modelPickerAwaiting[id] = Date(timeIntervalSinceNow:5)
        do {
            // Stage literal keystrokes with no submit. Verify the provider recognizes
            // the exact slash command on the live screen before sending Enter.
            try writeModelPickerKeys(row,keys:["/","m","o","d","e","l"])
            let staged = try readStagedModelCommand(id,provider:provider)
            let current = try resolve(id)
            guard Self.modelPickerIdle(current), modelPickerAllowed(current,provider:provider),
                  try liveScreen(current) == staged, stillSelected() else { throw HUDError("Model picker input changed.") }
            try writeModelPickerKeys(current,keys:["enter"])
        } catch {
            modelPickerUncertain.insert(id)
            modelPickerHolds[id] = Date()
            throw HUDError("Model picker input is uncertain. Check the terminal in Herdr before trying again.")
        }
    }

    private func readStagedModelCommand(_ id: String, provider: String) throws -> String {
        for attempt in 0..<4 {
            let row = try resolve(id)
            guard Self.modelPickerIdle(row), modelPickerAllowed(row,provider:provider) else {
                throw HUDError("The selected chat changed while opening its model picker.")
            }
            let screen = try liveScreen(row)
            if ModelPicker.stagedCommand(screen,provider:provider) { return screen }
            if attempt < 3 { Thread.sleep(forTimeInterval:0.1) }
        }
        throw HUDError("The chat did not show the staged model command.")
    }

    func modelPickerKey(_ id: String, token: String, key: String, stillSelected: () -> Bool) throws {
        guard !modelPickerUncertain.contains(id), let preview = modelPickerPreviews[id], preview.token == token,
              Date().timeIntervalSince(preview.date) < 15 else {
            throw HUDError("Model picker changed or expired. Review its current screen again.")
        }
        modelPickerPreviews.removeValue(forKey:id)
        guard let provider = Self.modelPickerProvider(try resolve(id)),
              let menu = ModelPicker.menu(preview.screen,provider:provider) else {
            throw HUDError("Model picker changed. Review its current screen again.")
        }
        if let target = menu.choices.first(where:{ $0.focusKey == key }) {
            let (focused,screen) = try highlightModelChoice(id,screen:preview.screen,menu:menu,target:target,
                                                           provider:provider,stillSelected:stillSelected)
            guard let action = focused.applyKey else {
                throw HUDError("The selected row has no verified session action.")
            }
            try applyModelChoice(id,screen:screen,menu:focused,key:action,provider:provider,stillSelected:stillSelected)
        } else if let edge = revealEdge(key,menu:menu) {
            let (focused,screen) = try highlightModelChoice(id,screen:preview.screen,menu:menu,target:edge,
                                                           provider:provider,stillSelected:stillSelected)
            let up = key == "reveal:up"
            guard up ? focused.canRevealPrevious : focused.canRevealNext else { return }
            let row = try checkedModelPickerRow(id,screen:screen,provider:provider,stillSelected:stillSelected)
            try sendModelNavigationKey(id,row:row,key:up ? "up" : "down")
        } else if key == menu.applyKey {
            try applyModelChoice(id,screen:preview.screen,menu:menu,key:key,provider:provider,stillSelected:stillSelected)
        } else if ["up","down","esc"].contains(key) {
            let row = try checkedModelPickerRow(id,screen:preview.screen,provider:provider,stillSelected:stillSelected)
            try sendModelNavigationKey(id,row:row,key:key)
        } else {
            throw HUDError("This key is unavailable for the current model selection.")
        }
    }

    private func revealEdge(_ key: String, menu: ModelPicker) -> ModelPicker.Choice? {
        if key == "reveal:up", menu.canRevealPrevious { return menu.entries.first }
        if key == "reveal:down", menu.canRevealNext { return menu.entries.last }
        return nil
    }

    private func highlightModelChoice(_ id: String, screen: String, menu: ModelPicker, target: ModelPicker.Choice,
                                      provider: String, stillSelected: () -> Bool) throws -> (ModelPicker,String) {
        guard let start = menu.entries.firstIndex(where:{ $0.selected }),
              let end = menu.entries.firstIndex(where:{ $0.key == target.key }) else {
            throw HUDError("The requested row is unavailable.")
        }
        if start == end { return (menu,screen) }
        let step = end > start ? 1 : -1
        let arrow = step == 1 ? "down" : "up"
        var focused = menu
        var checkedScreen = screen
        for index in stride(from:start+step,through:end,by:step) {
            let expected = menu.entries[index]
            let row = try checkedModelPickerRow(id,screen:checkedScreen,provider:provider,stillSelected:stillSelected)
            try sendModelNavigationKey(id,row:row,key:arrow)
            checkedScreen = try readUpdatedModelScreen(id,provider:provider,from:checkedScreen)
            guard let updated = ModelPicker.menu(checkedScreen,provider:provider), updated.heading == menu.heading,
                  updated.selectedChoice.matches(expected),
                  updated.entries.contains(where:{ $0.matches(target) }) else {
                throw HUDError("The model list changed while moving its selection. Review the current model list.")
            }
            focused = updated
        }
        return (focused,checkedScreen)
    }

    private func checkedModelPickerRow(_ id: String, screen: String, provider: String, stillSelected: () -> Bool) throws -> Row {
        let row = try resolve(id)
        guard Self.modelPickerIdle(row), modelPickerAllowed(row,provider:provider),
              try liveScreen(row) == screen else {
            throw HUDError("Model picker changed. Review its current screen again.")
        }
        let current = try resolve(id)
        guard Self.modelPickerIdle(current), modelPickerAllowed(current,provider:provider), stillSelected() else {
            throw HUDError("The selected chat changed before model picker input.")
        }
        return current
    }

    private func applyModelChoice(_ id: String, screen: String, menu: ModelPicker, key: String,
                                  provider: String, stillSelected: () -> Bool) throws {
        let row = try checkedModelPickerRow(id,screen:screen,provider:provider,stillSelected:stillSelected)
        try sendModelNavigationKey(id,row:row,key:key)
        do {
            _ = try readUpdatedModelScreen(id,provider:provider,from:screen) {
                menu.confirmsAction(key,on:$0,provider:provider)
            }
        } catch {
            modelPickerUncertain.insert(id)
            modelPickerHolds[id] = Date()
            throw HUDError("The model picker outcome is uncertain. Check the terminal in Herdr before trying again.")
        }
    }

    private func readUpdatedModelScreen(_ id: String, provider: String, from previous: String,
                                        accepting: (String) -> Bool = { _ in true }) throws -> String {
        for attempt in 0..<4 {
            let row = try resolve(id)
            guard Self.modelPickerIdle(row), modelPickerAllowed(row,provider:provider) else {
                throw HUDError("The selected chat changed during model navigation.")
            }
            let current = try liveScreen(row)
            if current != previous && accepting(current) { return current }
            if attempt < 3 { Thread.sleep(forTimeInterval:0.1) }
        }
        throw HUDError("The picker did not show the requested selection. Review its current screen.")
    }

    private func sendModelNavigationKey(_ id: String, row: Row, key: String) throws {
        modelPickerHolds[id] = Date()
        do { try writeModelPickerKeys(row,keys:[key]) }
        catch {
            modelPickerUncertain.insert(id)
            modelPickerHolds[id] = Date()
            throw HUDError("Model picker input is uncertain. Check the terminal in Herdr before trying again.")
        }
    }

    func reconcileModelPicker(_ id: String, stillSelected: () -> Bool) throws {
        let row = try resolve(id)
        guard let provider = Self.modelPickerProvider(row),
              modelPickerHolds[id].map({ Date().timeIntervalSince($0) >= 2 }) ?? true,
              try modelPickerReady(id,provider:provider), stillSelected() else {
            throw HUDError("Close the model picker or clear its input in Herdr, then check again.")
        }
        modelPickerHolds.removeValue(forKey:id)
        modelPickerAwaiting.removeValue(forKey:id)
        modelPickerUncertain.remove(id)
        modelPickerPreviews.removeValue(forKey:id)
    }

    func requireModelPickerClosed(_ id: String, row: Row) throws {
        guard let provider = Self.modelPickerProvider(row) else { return }
        let screen = try? liveScreen(row)
        let menuOpen = screen.map { ModelPicker.menu($0,provider:provider) != nil || ModelPicker.stagedCommand($0,provider:provider) } ?? false
        guard modelPickerHolds[id] == nil, !modelPickerUncertain.contains(id), !menuOpen else {
            throw HUDError("Finish the model picker in Herdr before sending a prompt.")
        }
    }

    private func modelPickerReady(_ id: String, provider: String) throws -> Bool {
        let row = try resolve(id)
        guard Self.modelPickerIdle(row), modelPickerAllowed(row,provider:provider),
              ModelPicker.blankComposer(try liveScreen(row),provider:provider) else { return false }
        let current = try resolve(id)
        return Self.modelPickerIdle(current) && modelPickerAllowed(current,provider:provider)
    }

    private func writeModelPickerKeys(_ row: Row, keys: [String]) throws {
        // The stock hc endpoint waits for quiet and has no atomic screen guard.
        // Review the screen before each write and never retry a write.
        let reply = try rpc([("terminal.keys",["terminal":row["terminal_id"]!,"keys":keys])],mutation:true)[0]
        guard let turn = reply["turn"] as? NSNumber, CFGetTypeID(turn) != CFBooleanGetTypeID(),
              turn.doubleValue >= 0, turn.doubleValue.rounded(.down) == turn.doubleValue else {
            throw HUDError("Invalid model picker key acknowledgement.")
        }
    }
}
