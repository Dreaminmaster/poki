// Poki's chat harness shares its core execution rules and harness tools (report_plan, finish_task)
// with agent/task-runner.mjs and agent/prompts/pi-app.md, adapted to the app's in-process tools
// (look, do, skills, status) and sandbox browser tools (WebTools). finish_task also takes a result
// card, which the chat draws and the Mac agent's terminal and message channels do not.
import Foundation
import PokiCore

/// One tool as the model sees it, before a provider puts it in its own form.
struct ToolSpec {
    var name: String
    var description: String
    var schema: [String: Any]
}

enum Harness {
    static let system: String = {
        guard let url = Bundle.main.url(forResource: "agent-system", withExtension: "md"), let text = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return text
    }()

    enum ReplyExamplesLanguage: Equatable, Sendable {
        case english, chinese, both
    }

    private static let automaticUnlockPromptClause = "Call the phone tool for the owner's task even if the iPhone may be locked. Poki checks the owner's Automatic Unlock setting on the phone. If the tool still reports screen: locked, ask the owner to unlock the iPhone and look again once unlocked."
    private static let manualUnlockPromptClause = "When look reports screen: locked, ask the owner to unlock the iPhone and call look again once unlocked."

    private static let replyExamplesHeader = "\n\n## Reply examples\n\n"
    private static let chineseExamplesHeader = "\n\n### 简体中文\n\n"

    private static let urlPattern = try! NSRegularExpression(pattern: #"https?://\S+"#, options: [.caseInsensitive])
    private static let languageCuePattern = try! NSRegularExpression(
        pattern: #"\b(chinese|mandarin|cantonese|english|japanese|korean|spanish|french|german|italian|portuguese|russian|arabic|hindi|thai|vietnamese|indonesian|malay|dutch|turkish|polish|swedish|greek|hebrew|ukrainian|bilingual)\b|\b(reply|answer|respond|write|speak|say|translate)\s+in\b|中文|汉语|漢語|普通话|普通話|粤语|粵語|国语|國語|英文|英语|英語|日文|日语|日語|韩文|韩语|韓文|韓語|法文|法语|法語|德文|德语|德語|西语|西班牙语|西班牙語|俄文|俄语|俄語|意语|意大利语|意大利語|葡语|葡萄牙语|葡萄牙語|阿拉伯语|阿拉伯語|泰语|泰語|双语|雙語|(?:用|以).{0,4}(?:语|語|文)(?:回复|回覆|回答|说|說|写|寫)"#,
        options: [.caseInsensitive]
    )
    private static let englishClauseWords: Set<String> = [
        "the", "and", "or", "to", "in", "on", "for", "of", "with", "is", "are",
        "please", "open", "check", "reply", "tell", "show", "find", "send", "scroll", "read",
    ]
    private static let hanPattern = try! NSRegularExpression(pattern: #"\p{Script=Han}"#)
    private static let latinWordPattern = try! NSRegularExpression(pattern: #"[A-Za-z]+"#)
    private static let screenshotIDLinePattern = try! NSRegularExpression(pattern: #"^screenshot_id: [0-9A-Fa-f-]+$"#)

    nonisolated static func replyExamplesLanguage(for task: String) -> ReplyExamplesLanguage {
        let fullRange = NSRange(task.startIndex..., in: task)
        let stripped = urlPattern.stringByReplacingMatches(in: task, range: fullRange, withTemplate: " ")
        let range = NSRange(stripped.startIndex..., in: stripped)
        if languageCuePattern.firstMatch(in: stripped, range: range) != nil {
            return .both
        }
        var hanCount = 0
        for scalar in stripped.unicodeScalars where !scalar.isASCII && scalar.properties.isAlphabetic {
            let s = String(scalar)
            if hanPattern.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil {
                hanCount += 1
            } else {
                return .both
            }
        }
        let latinWords = latinWordPattern.matches(in: stripped, range: range).compactMap { match -> String? in
            Range(match.range, in: stripped).map { String(stripped[$0]).lowercased() }
        }
        if hanCount == 0 {
            return latinWords.isEmpty ? .both : .english
        }
        if latinWords.isEmpty {
            return .chinese
        }
        if hanCount >= 4,
           latinWords.count <= 2,
           hanCount >= latinWords.count * 2,
           !latinWords.contains(where: { englishClauseWords.contains($0) }) {
            return .chinese
        }
        return .both
    }

    nonisolated static func systemPrompt(for task: String,
                                         includeAutomaticUnlock: Bool = AppModel.automaticUnlockAvailable) -> String {
        var text = system
        if !includeAutomaticUnlock {
            text = text.replacingOccurrences(of: automaticUnlockPromptClause, with: manualUnlockPromptClause)
        }
        let language = replyExamplesLanguage(for: task)
        guard language != .both,
              let examplesRange = text.range(of: replyExamplesHeader),
              let chineseRange = text.range(of: chineseExamplesHeader, range: examplesRange.upperBound..<text.endIndex) else {
            return text
        }
        let prefix = text[..<examplesRange.upperBound]
        switch language {
        case .english:
            return String(text[..<chineseRange.lowerBound])
        case .chinese:
            let chineseBody = text[chineseRange.upperBound...]
            return String(prefix) + "### 简体中文\n\n" + String(chineseBody)
        case .both:
            return text
        }
    }

    nonisolated static func strippingScreenshotID(from answer: PokiCore.ToolAnswer) -> PokiCore.ToolAnswer {
        guard answer.text.contains("screenshot_id: ") else { return answer }
        let lines = answer.text.split(separator: "\n", omittingEmptySubsequences: false)
        var removed = false
        let kept = lines.filter { line in
            let s = String(line)
            let range = NSRange(s.startIndex..., in: s)
            if screenshotIDLinePattern.firstMatch(in: s, range: range) != nil {
                removed = true
                return false
            }
            return true
        }
        guard removed else { return answer }
        return PokiCore.ToolAnswer(
            text: kept.joined(separator: "\n"),
            jpeg: answer.jpeg,
            isError: answer.isError,
            splitView: answer.splitView,
            splitViewNeedsRead: answer.splitViewNeedsRead,
            screen: answer.screen,
            waitingForOwner: answer.waitingForOwner,
            automationAuthorizationDeclined: answer.automationAuthorizationDeclined,
            numberedScreen: answer.numberedScreen,
            offeredMemories: answer.offeredMemories,
            readApp: answer.readApp
        )
    }

    static var instructions: String {
        [system, PokiCore.toolInstructions(includeScreenHistory: HistoryCapture.agentQueryAllowed), WebTools.instructions].joined(separator: "\n\n")
    }

    static let splitViewInstructions = """
    You are Poki, the owner's personal assistant, completing their task across two visible iPhone Split View apps while Poki stays in the background. Reply in the owner's language. Start with the result, then give the facts they need and anything you could not verify. Match their tone and length. Keep casual replies short and answer fully when they ask for explanation, comparison, advice, or steps. Use short paragraphs and plain bullets or hyphens for lists. Skip checkboxes and filler. Follow any stated preference for reply length or format. Publish a short plan with report_plan before acting.
    Start with look on pane left or right, and confirm the app identity and screen before acting. Call a fresh look when switching panes or after any layout change; restore both windows with the owner's help if the pair cannot be confirmed. Keep actions within these two apps and leave both windows in place.
    For cross-pane drag, read the destination pane first, then select the source pane with look and send do with {drag: {from: ref or [x,y], to: [x,y], to_pane: left or right}} using destination-local coordinates. Read the destination again to verify arrival, including the image itself for photos, and report unconfirmed transfers rather than risking duplicates.
    Check the target field and content before typing, and verify the result in the same pane. Wait for the owner's decision on approvals, leave password manager apps unopened, stop on checkout or payment pages unless purchase was explicitly requested, and use handoff for passwords, verification, or owner-only prompts. Call finish_task after verifying the final result, setting success=false when unverified.
    """

    private static let screenScrollInstruction = "For a request measured in pages or screens, scroll the requested number of screens and verify those moves with the screen tools."

    private static let countedScrollCoreInstructions = """
    Use count_messages only for requests measured in individual messages.
    For a request to scroll back an exact number of messages, open the conversation and take a full read before scrolling. Call count_messages with the requested target and one current ref per distinct message bubble, oldest to newest. Use the screenshot to exclude headers, dates, controls, and duplicate labels or OCR lines in the same bubble. Include every distinguishable message in view, including any overlapping messages. Do not skip a message you cannot identify.
    Send one vertical drag at a time with full=true, using two explicit screen points with the same x coordinate. Poki bounds the distance and slows the drag before lifting. After each drag, call count_messages with the same target and the new screen's refs. Keep at least one third of the previous messages in view, including at least three consecutive messages, using the same kind of ref for each overlapping bubble. Shorten the drag near the target or the end of the list. If count_messages asks you to reverse the last drag, reverse it and check the resulting page before trying the shorter forward drag. If that cannot be verified, stop. Use the confirmed total from count_messages. Call finish_task with success=true only after it confirms the target on screen. If you cannot continue, call finish_task with success=false and give the specific reason. Poki reports the confirmed count and last verified message.
    """

    private static let countedScrollReplyInstruction = "If you need clarification at any point during a counted scroll in the owner's chat, call wait_for_counted_scroll_reply with your question. That pauses the task. When the owner replies, take a fresh read and recheck the messages before scrolling again."

    private static func countedScrollSection(includeReply: Bool) -> String {
        includeReply ? countedScrollCoreInstructions + "\n" + countedScrollReplyInstruction : countedScrollCoreInstructions
    }

    /// Apps with dedicated result card layouts (`ResultCardLooks`).
    enum DedicatedCardApp: CaseIterable, Hashable, Sendable {
        case railway12306, ctrip, taobao, dianping, uberEats

        static func matching(bundleID: String) -> DedicatedCardApp? {
            switch bundleID.lowercased() {
            case "cn.12306.rails12306": .railway12306
            case "ctrip.com": .ctrip
            case "com.taobao.taobao4iphone": .taobao
            case "com.dianping.dpscope": .dianping
            case "com.ubercab.ubereats": .uberEats
            default: nil
            }
        }
    }

    /// Which result card schemas `finish_task` exposes for a task.
    enum ResultCardMode: Equatable, Hashable, Sendable {
        /// Omit `finish_task.card` completely (delegated tasks, system utility apps, explicit-URL web tasks).
        case none
        /// Expose generic `list` plus the dedicated layouts for `apps`.
        case scoped(Set<DedicatedCardApp>)

        static let all = ResultCardMode.scoped(Set(DedicatedCardApp.allCases))
        static let genericList = ResultCardMode.scoped([])

        /// Monotonically widens the mode when a task launches or reads an app during execution.
        /// Never shrinks mid-task so the provider's prompt-cache prefix stays stable.
        func including(app bundleID: String) -> ResultCardMode {
            let normalized = bundleID.lowercased()
            if normalized.isEmpty || normalized == "com.apple.springboard" || Harness.nonCardAppBundleIDs.contains(normalized) {
                return self
            }
            if let dedicated = DedicatedCardApp.matching(bundleID: normalized) {
                switch self {
                case .none: return .scoped([dedicated])
                case .scoped(var apps):
                    apps.insert(dedicated)
                    return .scoped(apps)
                }
            }
            switch self {
            case .none: return .genericList
            case .scoped: return self
            }
        }
    }

    /// System utility apps that never produce selectable catalog result cards.
    static let nonCardAppBundleIDs: Set<String> = [
        "com.apple.preferences",
        "com.apple.mobileslideshow",
        "com.apple.camera",
        "com.apple.mobiletimer",
        "com.apple.calculator",
        "com.apple.weather",
        "com.apple.mobilephone",
        "com.apple.mobilesms",
        "com.apple.facetime",
        "com.apple.mobileaddressbook",
        "com.apple.health",
        "com.apple.fitness",
        "com.apple.home",
        "com.apple.voicememos",
        "com.apple.translate",
        "com.apple.findmy",
        "com.apple.passwords",
        "com.apple.shortcuts",
        "com.apple.passbook",
    ]

    /// Chooses the initial result-card schema scope for a task without natural-language intent guessing.
    /// Delegated tasks never render cards; tasks explicitly naming only system utility apps or an explicit
    /// http(s) URL without a phone app omit `card` until a card-capable app is observed. Tasks naming a
    /// card-capable app scope `card` to that app's dedicated kinds plus generic `list`; open-ended tasks
    /// with no named app keep all card kinds.
    static func resultCardMode(for task: String, rendersCards: Bool) -> ResultCardMode {
        guard rendersCards else { return .none }
        var namedApps: [String] = []
        for segment in CapsuleText.segments(task) {
            if case .app(let capsule, _) = segment {
                let id = capsule.id.lowercased()
                if !namedApps.contains(id) { namedApps.append(id) }
            }
        }
        if !namedApps.isEmpty {
            if namedApps.allSatisfy({ nonCardAppBundleIDs.contains($0) }) { return .none }
            return .scoped(Set(namedApps.compactMap(DedicatedCardApp.matching(bundleID:))))
        }
        if task.range(of: #"https?://\S+"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return .none
        }
        return .all
    }

    /// The instructions for a task: the above, then the saved notes and the skills that fit it.
    @MainActor static func taskInstructions(for task: String, inSplitView: Bool = false,
                                            includeMemoryAttribution: Bool? = nil,
                                            includeCountedScroll: Bool? = nil,
                                            includeCountedScrollReply: Bool? = nil,
                                            includeAutomaticUnlock: Bool = AppModel.automaticUnlockAvailable) -> (text: String, notes: [MemoryNote]) {
        let countedScroll = includeCountedScroll ?? (MessageScrollTarget.parse(task)?.messageCount != nil)
        let countedScrollReply = includeCountedScrollReply ?? countedScroll
        if inSplitView {
            var parts = [splitViewInstructions, screenScrollInstruction]
            if countedScroll { parts.append(countedScrollSection(includeReply: countedScrollReply)) }
            if HistoryCapture.agentQueryAllowed { parts.append(PokiCore.screenHistoryInstructions) }
            if ApprovalClassifier.mode == .reply { parts.append(replyApprovals) }
            return (parts.joined(separator: "\n\n"), [])
        }
        let namedBundleIDs = AppIconStore.bundleIDs(namedIn: task)
        let brief = SkillStore.shared.taskBrief(for: task, apps: namedBundleIDs)
        var parts = [systemPrompt(for: task, includeAutomaticUnlock: includeAutomaticUnlock), screenScrollInstruction]
        if countedScroll { parts.append(countedScrollSection(includeReply: countedScrollReply)) }
        parts.append(PokiCore.toolInstructions(includeScreenHistory: HistoryCapture.agentQueryAllowed))
        parts.append(WebTools.instructions)
        parts.append("To continue or resume, match one unfinished task from this conversation or an explicitly selected saved task; if none or several match, ask which task before calling action tools. Treat long-term notes and saved skills strictly as preferences and reusable steps, never pending tasks.")
        // Matching skills sit in the brief below, so the first call can invoke the skill directly.
        // Poki is in front when a task starts, and finish_task brings Poki back when the task ends,
        // so saving a new skill happens in the same reply as finish_task.
        parts.append("Start an app task with do {run: name} when a skill below fits, else do {launch: bundle id}, sending report_plan with that first action and updating currentStep as you progress. When an app's bundle id is not listed below, or a launch answers that no app with that bundle id is installed, call find_app {name} before anything else and launch the id it gives; never launch an id from memory. Say an app is not installed only after find_app says so, and then give the owner the App Store link it found. When find_app says more than one app could be the one, ask the owner which instead of picking. If find_app cannot read the installed apps, send do {button: \"home\"} by itself. Use the returned screen to swipe down on the Home Screen to search, then type the app's name and tap the matching result. Recommend an app the owner does not have only when the task really needs one that no installed app and the built-in browser (web tools) can do: find it with find_app {purpose}, name it, and give its App Store link; never install apps. When you already know the taps a part of the task takes, send them as one do {path: {goal, steps}} with each target named by the text it shows, in place of one call per tap. In a path, put expect: \"text\" on a step whose result you can name, dismiss: [...] for prompts that may be closed on the way, and read: [\"label\"] when the task is to read a value, so the whole task is one call. After a new app task succeeds, call finish_task together with skills {action: \"save\", name, description} named as the owner would ask for it.")
        if AutomationPath.current == .inProcess, let placement = PKInProcess.shared().duoPlacement() {
            if placement == "fullscreen" {
                parts.append("Poki is full screen on Duo. Use the normal app task flow without selecting a pane.")
            } else if placement == "split-unknown" {
                parts.append("Poki is in Duo Split View and the task's side is not confirmed yet. Start with look without a pane argument. Wait for the read to confirm the task's app and pane before sending input. Ask the owner for help if the side stays unconfirmed.")
            } else {
                let target = placement == "left" ? "right" : "left"
                parts.append("Poki starts in the \(placement) pane of Duo Split View. This task uses the app in the \(target) pane, even when the owner replaces Poki with another app. Use look with no pane argument for that app, or do {launch: bundle id} to confirm it is already there. If the intended app is missing, ask the owner to open it in the \(target) pane and retry the task. Do not go Home, start a fresh launch, or drag across panes.")
            }
        }
        // A model decides approvals from what the owner said. A refused step goes through once the
        // owner says yes to it, so the agent asks in words and tries again.
        if ApprovalClassifier.mode == .reply {
            parts.append(replyApprovals)
        }
        parts.append(recipients)
        if includeMemoryAttribution ?? !SkillStore.shared.notes.isEmpty {
            parts.append("When a saved memory changes an action in do, add used_memory_ids: [\"ID\"] on that item in actions or path.steps (not outer path/run), or on web_open/web_click/web_type. For a saved skill, check numbered steps via skills show and set run.step_memory_ids (1-based, e.g. {\"2\":[\"ID\"]}). Report only IDs that drove the action.")
        }
        parts.append("A skill or memory you ask to save is kept only after finish_task(success=true); call finish_task even for remember-only tasks and skip failed/interrupted attempts. Set optional=true only on unrequested automatic saves; omit it when requested.")
        if let apps = appIDs(namedBundleIDs) { parts.append(apps) }
        if !brief.text.isEmpty { parts.append(brief.text) }
        return (parts.joined(separator: "\n\n"), brief.notes)
    }

    /// A result card's send button names the recipient only when the notes do (the card's description).
    private static let recipients = "When the owner asks to send something and neither the request nor the long-term notes name the recipient, ask the owner who to send it to before acting."

    private static let replyApprovals = "Approvals in this chat come from the owner's messages. When a step is declined, do not tell the owner to tap anything: ask in plain words whether to run that named step, and resend the identical step once confirmed."

    /// The iPhone bundle ids of the apps the owner's request names, from the list behind the app pills
    /// (KnownApps). Without them the model guessed: a tester's 淘宝 and 美团 tasks (Nov 13 2026) were
    /// refused as "no app with that bundle id is installed", and the agent told the owner to install
    /// apps they had. nil when the request names no listed app.
    private static func appIDs(_ bundleIDs: [String]) -> String? {
        let apps = bundleIDs.compactMap { KnownApps.byID[$0.lowercased()] }
        guard !apps.isEmpty else { return nil }
        let lines = apps.map { app -> String in
            let names = app.names.joined(separator: " / ")
            let others = app.otherIDs.isEmpty ? "" : " (another edition: \(app.otherIDs.joined(separator: ", ")))"
            return "- \(names): \(app.id)\(others)"
        }
        return "Use these iPhone bundle ids for apps named in this request:\n" + lines.joined(separator: "\n")
    }

    /// Poki's sandbox browser tools sit beside the phone tools.
    static var tools: [ToolSpec] {
        toolSpecs(inSplitView: false, includeScreenHistory: HistoryCapture.agentQueryAllowed)
    }

    /// Bundle ids from the phone's own app list, with the App Store's search as the backup (InstalledApps).
    static let findApp = ToolSpec(
        name: "find_app",
        description: "Find an app on this iPhone and its bundle id for {launch}. name: the app's name in any language (\"淘宝\", \"Notes\"); answers the installed apps with that name from the phone's own app list, or, when none is installed, the App Store's matches marked not installed with their links. purpose: what an app should do (\"parking\"); answers App Store apps for it, installed ones first, with links for the others. Launch only ids it says are installed. When it says it could not tell, the app may still be there.",
        schema: ["type": "object", "properties": ["name": string, "purpose": string], "additionalProperties": false])

    static var splitViewTools: [ToolSpec] {
        toolSpecs(inSplitView: true, includeScreenHistory: HistoryCapture.agentQueryAllowed)
    }

    /// A Pi loop holds executable implementations, even for tools currently withheld.
    /// The current permission determines which ones are declared for each request.
    static func toolSpecs(inSplitView: Bool, includeScreenHistory: Bool,
                          includeMemoryAttribution: Bool = true,
                          includeCountedScroll: Bool = true,
                          includeCountedScrollReply: Bool = true,
                          resultCardMode: ResultCardMode = .all) -> [ToolSpec] {
        let taskTools = Self.taskTools(includeCountedScroll: includeCountedScroll,
                                       includeCountedScrollReply: includeCountedScrollReply,
                                       resultCardMode: resultCardMode)
        if !inSplitView {
            let webTools = includeMemoryAttribution ? WebTools.specs.map(withActionMemoryIDs) : WebTools.specs
            return catalogTools(includeScreenHistory: includeScreenHistory, includeMemoryAttribution: includeMemoryAttribution) + [findApp] + webTools + taskTools
        }
        return [
            ToolSpec(name: "look", description: "Read the app, numbered UI elements and screenshot of the left or right pane. Select a pane explicitly when you first read and whenever moving between apps. Points use the selected screenshot’s own coordinates.",
                     schema: object(["pane": ["type": "string", "enum": ["left", "right"]], "full": ["type": "boolean"]], [])),
            ToolSpec(name: "do", description: "Act in the selected pane, then read it. Actions include {tap: ref or [x,y]}, {type: text, ref?: number}, {key: return|delete|tab|space|escape}, {scroll_to: text}, {swipe: direction}, {back: true}, {wait_until: text}, {handoff: {kind, text}}, and {drag: {from: ref or [x,y], to: [x,y], to_pane: left or right}} for a continuous cross-pane drag. Read the destination first and the source second. The drop point uses destination-local coordinates. Read the destination after sending the drag. Do not switch apps or end Split View.",
                     schema: object(["actions": ["type": "array", "items": ["type": "object"], "minItems": 0, "maxItems": 20], "full": ["type": "boolean"]], ["actions"])),
        ] + catalogTools(includeScreenHistory: includeScreenHistory, includeMemoryAttribution: includeMemoryAttribution).filter { $0.name == "status" || $0.name == "screen_history" } + taskTools
    }

    /// Keep the cached task prompt consistent with the current tool catalog.
    nonisolated static func historyInstructions(_ text: String, allowed: Bool) -> String {
        let instruction = PokiCore.screenHistoryInstructions
        if allowed {
            return text.contains(instruction) ? text : text + "\n\n" + instruction
        }
        return text.replacingOccurrences(of: instruction, with: "")
    }

    /// PokiCore's catalog: look, do and status.
    static let phoneTools: [ToolSpec] = catalogTools(includeScreenHistory: false, includeMemoryAttribution: true)
    nonisolated static let memoryUsingActions: Set<String> = ["do", "web_open", "web_click", "web_type"]

    private static func withActionMemoryIDs(_ tool: ToolSpec) -> ToolSpec {
        guard memoryUsingActions.contains(tool.name), var properties = tool.schema["properties"] as? [String: Any] else { return tool }
        var tool = tool
        properties["used_memory_ids"] = [
            "type": "array", "items": string, "maxItems": 20,
            "description": tool.name == "do"
                ? "Single non-path/run action only; else put on the action, path.steps item, or run.step_memory_ids."
                : "Memory IDs that drove this action.",
        ] as [String: Any]
        tool.schema["properties"] = properties
        return tool
    }

    nonisolated static func withoutActionMemoryIDs(_ tool: ToolSpec) -> ToolSpec {
        guard memoryUsingActions.contains(tool.name),
              var properties = tool.schema["properties"] as? [String: Any],
              properties.removeValue(forKey: "used_memory_ids") != nil else { return tool }
        var tool = tool
        tool.schema["properties"] = properties
        return tool
    }

    private static func catalogTools(includeScreenHistory: Bool, includeMemoryAttribution: Bool) -> [ToolSpec] {
        guard let data = PokiCore.toolCatalogJSON(includeScreenHistory: includeScreenHistory).data(using: .utf8),
              let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return [] }
        return list.compactMap { tool in
            guard let name = tool["name"] as? String, let description = tool["description"] as? String, let schema = tool["inputSchema"] as? [String: Any] else { return nil }
            let spec = ToolSpec(name: name, description: description, schema: schema)
            return includeMemoryAttribution ? withActionMemoryIDs(spec) : spec
        }
    }

    private nonisolated static func object(_ properties: [String: Any], _ required: [String]) -> [String: Any] {
        ["type": "object", "properties": properties, "required": required, "additionalProperties": false]
    }
    private nonisolated static let string: [String: Any] = ["type": "string"]
    private static func taskTools(includeCountedScroll: Bool,
                                  includeCountedScrollReply: Bool,
                                  resultCardMode: ResultCardMode) -> [ToolSpec] {
        var tools = [reportPlan]
        if includeCountedScroll {
            tools.append(countMessages)
            if includeCountedScrollReply {
                tools.append(waitForCountedScrollReply)
            }
        }
        tools.append(finishTask(resultCardMode: resultCardMode))
        return tools
    }

    static let reportPlan = ToolSpec(
        name: "report_plan",
        description: "Publish a plan before actions. Update currentStep (1-based) on each step. title names the task in two to four words, as a heading in the user's language (\"Text Mom\", \"Order the usual\"), not the user's sentence; send it with the first plan. When the task sends a message to someone, to is that person as the user named them (\"Mom\"); leave it out otherwise.",
        schema: object(["steps": ["type": "array", "items": string, "minItems": 1, "maxItems": 8], "currentStep": ["type": "integer", "minimum": 1, "maximum": 8], "title": string, "to": string], ["steps", "currentStep"]))

    static let countMessages = ToolSpec(
        name: "count_messages",
        description: "Check one screen in a counted message scroll. target is the owner's requested number of older messages. refs are the ordered message bubbles from the latest full screen read. The first screen sets the starting point. Each subsequent screen needs an ordered overlap with the last confirmed screen.",
        schema: object(["target": ["type": "integer", "minimum": 1],
                        "refs": ["type": "array", "items": ["type": "integer"], "minItems": 1, "maxItems": 1000]],
                       ["target", "refs"]))

    static let countedScrollReplyTool = "wait_for_counted_scroll_reply"
    private static let waitForCountedScrollReply = ToolSpec(
        name: countedScrollReplyTool,
        description: "Pause a counted message scroll in the owner's chat and ask for the information you need to continue it. The question is shown to the owner with a reply button.",
        schema: object(["question": string], ["question"]))

    static let finishTask = finishTask(resultCardMode: .all)

    nonisolated static func finishTask(resultCardMode: ResultCardMode) -> ToolSpec {
        var properties: [String: Any] = [
            "success": ["type": "boolean"], "summary": string,
            "details": ["type": "array", "items": object(["label": string, "value": string], ["label", "value"])],
            "answer": object([
                "kind": ["type": "string", "enum": ["action", "field", "list"]],
                "items": ["type": "array", "items": object(["ref": string, "field": ["type": "string", "enum": ["label", "value"]], "prefix": string, "suffix": string], ["ref", "field"])],
                "start_ref": string, "end_ref": string,
            ], ["kind"]),
        ]
        if case .scoped(let apps) = resultCardMode {
            properties["card"] = resultCard(for: apps)
        }
        return ToolSpec(
            name: "finish_task",
            description: "Finish after observing the requested result. On failure set success=false and say what worked, what blocked completion and what you tried. In details give the requested facts as whole current labels or values. Set answer.kind to action only for an executed change, field for fixed values, or list for requested entries. For field, use current refs and label/value. For a label like Capacity,90%, use prefix Capacity, and suffix % to identify the field. For list, include all requested current rows in order with names/times. Use start_ref/end_ref only for unique labels immediately outside the rows. Never invent refs or report a heading as a requested value.",
            schema: object(properties, ["success", "summary", "details", "answer"]))
    }

    /// finish_task's card, scoped to `apps`'s dedicated layouts plus generic `list` (`ResultCardLooks`).
    private nonisolated static func resultCard(for apps: Set<DedicatedCardApp>) -> [String: Any] {
        let action = object(["label": string, "say": string], ["label", "say"])
        let seat = object(["name": string, "left": string], ["name", "left"])
        var fields = ["subtitle", "detail", "value", "value_note", "note", "heading", "subheading"]
        if apps.contains(.railway12306) {
            fields += ["date", "from", "to", "depart", "arrive", "duration", "price"]
        }
        if apps.contains(.ctrip) {
            fields += ["date", "from", "to", "depart", "arrive", "duration", "price", "from_city", "to_city", "arrive_day", "stops",
                       "airline", "cabin", "city", "dates", "stars", "rating", "reviews", "location", "was", "total", "hotel",
                       "beds", "breakfast", "cancel", "trip", "baggage", "refund", "ticketing"]
        }
        if apps.contains(.taobao) {
            fields += ["query", "price", "price_label", "sold", "shop", "delivery"]
        }
        if apps.contains(.dianping) {
            fields += ["query", "rating", "reviews", "price", "category", "area", "distance"]
        }
        if apps.contains(.uberEats) {
            fields += ["store", "price", "calories"]
        }
        var properties: [String: Any] = Dictionary((["id", "title"] + fields).map { ($0, string) }, uniquingKeysWith: { first, _ in first })
        if apps.contains(.railway12306) {
            properties["seats"] = ["type": "array", "items": seat]
        }
        var legProperties: [String: Any] = ["number": string, "from": string, "to": string, "depart": string, "arrive": string,
                                            "arrive_day": string, "wait": string, "change": string]
        if apps.contains(.railway12306) {
            legProperties["seats"] = ["type": "array", "items": seat]
        }
        let leg = object(legProperties, ["number"])
        properties["legs"] = ["type": "array", "items": leg, "minItems": 2]
        properties["image"] = ["type": "array", "items": ["type": "number"], "minItems": 4, "maxItems": 4,
                               "description": "[x, y, width, height] of the complete photo itself in the screenshot named by image_screenshot. The bounds exclude the row, text, and controls."]
        properties["image_screenshot"] = ["type": "string", "description": "Copy the screenshot_id from the tool answer whose screenshot supplied this item's image coordinates."]
        let item = object(properties, ["id", "title"])
        var kinds: [String] = []
        if apps.contains(.railway12306) { kinds += [RailwayTrains.kind, RailwayTransfers.kind] }
        if apps.contains(.ctrip) { kinds += [Ctrip.flights, Ctrip.hotels, Ctrip.rooms, Ctrip.fares] }
        if apps.contains(.taobao) { kinds.append(Taobao.kind) }
        if apps.contains(.dianping) { kinds.append(Dianping.kind) }
        if apps.contains(.uberEats) { kinds.append(UberEats.kind) }
        kinds.append(AnyAppList.kind)
        var card = object(["app": string, "kind": ["type": "string", "enum": kinds],
                           "items": ["type": "array", "items": item, "minItems": 1], "recommended": string,
                           "primary": action, "next": action], ["app", "kind", "items", "recommended", "primary"])
        card["description"] = cardDescription(for: apps)
        return card
    }

    private nonisolated static func cardDescription(for apps: Set<DedicatedCardApp>) -> String {
        var kindLines: [String] = []
        if apps.contains(.railway12306) {
            kindLines.append("12306.trains (cn.12306.rails12306): Always use this card for direct train results in 12306. id and title are the train number, date is the displayed date, from/to are stations, depart/arrive are times. Include duration, price and seats [{name, left}]. primary: 在 12306 查看 / 在 12306 打开 {date} {title} 次（{from} {depart} 开）. For sending a train, put the recipient from long-term notes in label and say, using {date} and {title} in say. If no note names a recipient, use label 发送车次 and leave the recipient for the owner. Never offer paying, booking or choosing seats for 12306.")
            kindLines.append("12306.transfers (cn.12306.rails12306): title is the trains joined by →. Include date, from/to, depart/arrive, total duration, price and ordered legs [{number, from, to, depart, arrive, wait, change, seats: [{name, left}]}]. wait is the layover, change describes the transfer shown. primary: 在 12306 查看 / 在 12306 打开 {date} {title}（{from} {depart} 开）.")
        }
        if apps.contains(.ctrip) {
            kindLines.append("ctrip.flights (ctrip.com): title is the flight numbers joined by >. Include depart, arrive, arrive_day (arrival day offset), from/to airports, from_city/to_city, date, duration, stops, airline, cabin, price and, for connections, ordered legs [{number, from, to, depart, arrive, wait, change}]. primary: 在携程查看 / 在携程打开 {date} {title}（{depart} 起飞，{price}）.")
            kindLines.append("ctrip.hotels (ctrip.com): title is the hotel name. Include subtitle (other name), stars, rating, reviews, location, price (per night), was (original price) and total (stay total). Put city and dates on the first item. primary: 在携程查看 / 在携程打开 {title}（{price}）.")
            kindLines.append("ctrip.rooms (ctrip.com): title is the room type. Include beds, breakfast, cancel, price (per night), was (original price) and total (stay total). Put the shared hotel on the first item and dates (stay dates) on every room for the heading and selected button. primary: 在携程查看 / 在携程打开 {hotel} 的 {title}（{dates}，{price}）.")
            kindLines.append("ctrip.fares (ctrip.com): title is the fare name. Include price, cabin, baggage, refund (refund and change rules) and ticketing. Put trip and dates on the first item. primary: 在携程查看 / 在携程打开 {title} {price} 这个票价.")
        }
        if apps.contains(.taobao) {
            kindLines.append("taobao.products (com.taobao.taobao4iphone): Include title, price, price_label (e.g. 补贴价), sold, shop and delivery. Put query on the first item. primary: 在淘宝查看 / 在淘宝打开 {shop} 的 {title}（{price}）.")
        }
        if apps.contains(.dianping) {
            kindLines.append("dianping.places (com.dianping.dpscope): Include title, subtitle, rating, reviews, price, category, area and distance. Put query on the first item. primary: 在大众点评查看 / 在大众点评打开 {title}.")
        }
        if apps.contains(.uberEats) {
            kindLines.append("ubereats.items (com.ubercab.UberEats): Include title, price, detail (what comes with it) and calories. Put store on the first item. primary: View in Uber Eats / Open {title} ({price}) in Uber Eats.")
        }
        kindLines.append("list (any other app, with its own bundle ID): Include title, subtitle, detail, value (the deciding price, time or rating) and value_note. For a journey with connections, use ordered legs as in flights. Put heading and subheading on the first item. Use a dedicated kind where one exists. primary: 在<app>查看 / 在<app>打开 {title}.")
        return [
            "Use a result card for one or more selectable items from one app, even if the owner asks for only one. The card replaces the reply's list. Omit it for other results. Use the owner's language. Copy values as shown and omit fields the screen does not show. Use note for a fact that affects the choice.",
            "Fields below are per item unless stated. Use the kind and app ID listed. Select the best item with recommended (its id). primary and optional next have label (shown on the button) and say (sent as the owner's next message). The card fills {field} from the selected item. Use fields available to that item so the message stands alone with its key facts. Omit next when no clear follow-up exists.",
            kindLines.joined(separator: "\n"),
            "For pictured items, send image (bounds of the complete photo itself) and image_screenshot (screenshot_id from the same observation) together. The bounds exclude the row, text, and controls. Items may use different screenshots. Omit both fields if the full photo is clipped or there is no screenshot_id. Never guess.",
        ].joined(separator: "\n\n")
    }

    /// task-runner.mjs's answers to its harness tools.
    static let planPublished = "Plan published. Continue."
    static let resultRecorded = "Result recorded. Tell the user the outcome, the facts they need, and anything you could not verify."

    /// With a card, the reply adds context for the user's decision. Without a card, the reply gives the whole result.
    static func recorded(_ result: TaskResult, cardShown: Bool) -> String {
        if cardShown {
            return "Result recorded. The card under the task shows the items and their buttons. Add what matters for the user's decision, such as why the recommended item fits or what to watch for. Skip details already in the card unless the user needs them in the explanation or asks for them."
        }
        if let problem = result.cardProblem {
            return "Result recorded. The card was not shown (\(problem)), so give the whole result in words, as without a card."
        }
        return resultRecorded
    }

    static let invalidPlan = "Invalid model plan"
    static let invalidResult = "Invalid task result"
}
