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
        let row = try resolve(id)
        guard let provider = Self.modelPickerProvider(row), Self.modelPickerIdle(row), modelPickerAllowed(row,provider:provider),
              let menu = ModelPicker.menu(preview.screen,provider:provider),
              try liveScreen(row) == preview.screen else { throw HUDError("Model picker changed. Review its current screen again.") }
        let current = try resolve(id)
        guard Self.modelPickerIdle(current), modelPickerAllowed(current,provider:provider), stillSelected() else {
            throw HUDError("The selected chat changed before model picker input.")
        }
        if let target = menu.choices.first(where:{ $0.focusKey == key }) {
            try highlightModelChoice(id,row:current,screen:preview.screen,menu:menu,target:target,
                                     provider:provider,stillSelected:stillSelected)
        } else {
            guard ["up","down","esc"].contains(key) || menu.applyKey == key else {
                throw HUDError("This key is unavailable for the current model selection.")
            }
            try sendModelNavigationKey(id,row:current,key:key)
        }
    }

    private func highlightModelChoice(_ id: String, row: Row, screen: String, menu: ModelPicker, target: ModelPicker.Choice,
                                      provider: String, stillSelected: () -> Bool) throws {
        guard let selectedNumber = Int(menu.selectedChoice.key), let targetNumber = Int(target.key),
              abs(targetNumber-selectedNumber) <= 9 else { throw HUDError("The requested row is out of range.") }
        let step = targetNumber > selectedNumber ? 1 : -1
        let arrow = step > 0 ? "down" : "up"
        var currentNumber = selectedNumber
        var current = row
        var checkedScreen = screen
        // A numbered Codex shortcut can apply a default immediately for a model
        // with one effort. Clicking a row moves focus and never submits it.
        while currentNumber != targetNumber {
            guard stillSelected() else { throw HUDError("The selected chat changed during model navigation.") }
            try sendModelNavigationKey(id,row:current,key:arrow)
            currentNumber += step
            current = try resolve(id)
            guard Self.modelPickerIdle(current), modelPickerAllowed(current,provider:provider) else {
                throw HUDError("The selected chat changed during model navigation.")
            }
            checkedScreen = try readUpdatedModelScreen(current,from:checkedScreen)
            guard let updated = ModelPicker.menu(checkedScreen,provider:provider), updated.heading == menu.heading,
                  Int(updated.selectedChoice.key) == currentNumber,
                  updated.choices.contains(where:{ $0.key == target.key && $0.label == target.label }) else {
                throw HUDError("The model list changed while moving its selection. Review the current model list.")
            }
        }
    }

    private func readUpdatedModelScreen(_ row: Row, from previous: String) throws -> String {
        for attempt in 0..<4 {
            let current = try liveScreen(row)
            if current != previous { return current }
            if attempt < 3 { Thread.sleep(forTimeInterval:0.04) }
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
        // Send one reviewed key per navigation click and never retry a write.
        let reply = try rpc([("terminal.keys",["terminal":row["terminal_id"]!,"keys":keys])],mutation:true)[0]
        guard let turn = reply["turn"] as? NSNumber, CFGetTypeID(turn) != CFBooleanGetTypeID(),
              turn.doubleValue >= 0, turn.doubleValue.rounded(.down) == turn.doubleValue else {
            throw HUDError("Invalid model picker key acknowledgement.")
        }
    }
}
