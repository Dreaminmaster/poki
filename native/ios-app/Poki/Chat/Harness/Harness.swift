// The chat's prompt and tools are the Mac Poki Agent's, copied from this repository at main 729c77e:
// - agent-system.md is agent/prompts/system.md (the same text as agent/prompts/pi-app.md, which
//   agent/task-runner.mjs loads), except two sentences that named tools the app lacks: a locked phone
//   is the owner's to unlock and a password prompt is handed to them, and a purchase is a plain tap;
//   and, for ESP-465, the Return sentence names the type answer's read-back as the check before
//   Return, an action's check lines (the send check after Return) count as evidence, and finish_task
//   comes in the reply right after the observation that verifies the result; and, for ESP-471, a task
//   that cannot be completed is one beyond the tools, since a missing choice is asked in the chat;
// - the instructions put PokiCore's own MCP instructions first, as task-runner.mjs puts the MCP server's
//   instructions first;
// - look, do and status are PokiCore's tools with their MCP descriptions;
// - report_plan and finish_task are task-runner.mjs's harness tools (#startModel), descriptions and
//   schemas unchanged.
// Not copied, because the app has none of their tools: agent/prompts/call-draft.md and
// agent/skills/iphone-unlock/SKILL.md, unlock_device and handle_alert.
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

    static var instructions: String { [PokiCore.toolInstructions, system].joined(separator: "\n\n") }

    /// The instructions for a task: the above, then the saved notes and the routines that fit it.
    @MainActor static func instructions(for task: String) -> String {
        let brief = PokiCore.memoryBrief(for: task)
        var parts = [instructions]
        // Poki learns the owner's repeated tasks: a saved routine runs them in one call next time.
        // The routines that fit are in the brief below, so the first call can be the routine itself:
        // listing them first cost a whole model turn before anything happened on the phone. Poki is in
        // front when a task begins, so a first look reads only the owner's chat (ESP-465). finish_task
        // ends the chat's task and the app brings Poki back (chatTaskEnded), so a finish: true do is a
        // step more; the save rides in the same reply instead of a turn before it.
        parts.append("Start the task in your first reply: ask the owner when their words already leave a choice open, else do {run: name} with the routine below that covers it, else do {launch: bundle id} with the app it needs. Send report_plan together with that first do. Finish in one reply: finish_task, which also brings the phone back to this chat, and with it routines {action: \"save\", name, description} when the task worked and was not a routine yet, named the way the owner would ask for it.")
        // Two kinds of unclear (ESP-471): an operation the model settles by trying, and a choice made
        // for the owner, which is asked when it costs money or is hard to undo and nothing settles it.
        parts.append("Settle every operation yourself: which app, where to tap, which route, what a page holds; try it and look. A choice is a pick made for the owner, such as which hospital branch and department, a date or time they did not give, which of two contacts with the same name, or which product option. Take a choice yourself when their words, the saved notes or the screen give a default for it (a usual or nearest store, a size already selected, the default address or payment), and name what you chose in your reply. Ask the owner about every other choice that costs money or is hard to undo: one reply without tool calls that holds every open choice, each with its options numbered as the screen lists them; the task stays open, and its submit step waits for their answer. Ask on the page that shows the options when they are not known before. Keep each answer with routines {action: \"remember\", text} so the next task of its kind starts from it.")
        // A model decides approvals from what the owner said. A refused step goes through once the
        // owner says yes to it, so the agent asks in words and tries again.
        if ApprovalClassifier.mode == .reply {
            parts.append("Approvals here are decided from what the owner said in this chat. When a step is refused (declined), do not tell the owner to tap anything: ask them in plain words whether they want that step done, naming the step, and if they say yes, send the same step again.")
        }
        if !brief.isEmpty { parts.append(brief) }
        return parts.joined(separator: "\n\n")
    }

    static let tools: [ToolSpec] = phoneTools + [reportPlan, finishTask]

    /// PokiCore's catalog: look, do and status.
    static let phoneTools: [ToolSpec] = {
        guard let data = PokiCore.toolCatalogJSON.data(using: .utf8), let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return [] }
        return list.compactMap { tool in
            guard let name = tool["name"] as? String, let description = tool["description"] as? String, let schema = tool["inputSchema"] as? [String: Any] else { return nil }
            return ToolSpec(name: name, description: description, schema: schema)
        }
    }()

    private static func object(_ properties: [String: Any], _ required: [String]) -> [String: Any] {
        ["type": "object", "properties": properties, "required": required, "additionalProperties": false]
    }
    private static let string: [String: Any] = ["type": "string"]

    static let reportPlan = ToolSpec(
        name: "report_plan",
        description: "Publish a plan before phone actions. Update currentStep (1-based) on each step. title names the task in two to four words, as a heading in the user's language (\"Text Mom\", \"Order the usual\"), not the user's sentence; send it with the first plan. When the task sends a message to someone, to is that person as the user named them (\"Mom\"); leave it out otherwise.",
        schema: object(["steps": ["type": "array", "items": string, "minItems": 1, "maxItems": 8], "currentStep": ["type": "integer", "minimum": 1, "maximum": 8], "title": string, "to": string], ["steps", "currentStep"]))

    static let finishTask = ToolSpec(
        name: "finish_task",
        description: "Finish after the last observation verifies the requested result. If unable to complete, set success=false and explain what was completed, what blocked completion and what was tried. details must contain the requested facts, not only a page title; every value must match a whole current label or value. Declare answer.kind: action for a performed change, field for fixed values, list for requested entries. Read tasks must never use action. For field, items select current refs and label/value; when a field is combined into a label such as \"Capacity,90%\", use prefix \"Capacity,\" and suffix \"%\" to preserve the field identity while reading a new value. For list, items select all requested current rows in order with their names/times; start_ref and end_ref identify unique section labels immediately before and after those rows. Omit section refs if no reliable boundaries exist. Never invent refs or use a heading as a requested value.",
        schema: object([
            "success": ["type": "boolean"], "summary": string,
            "details": ["type": "array", "items": object(["label": string, "value": string], ["label", "value"])],
            "answer": object([
                "kind": ["type": "string", "enum": ["action", "field", "list"]],
                "items": ["type": "array", "items": object(["ref": string, "field": ["type": "string", "enum": ["label", "value"]], "prefix": string, "suffix": string], ["ref", "field"])],
                "start_ref": string, "end_ref": string,
            ], ["kind"]),
        ], ["success", "summary", "details", "answer"]))

    /// task-runner.mjs's answers to its harness tools.
    static let planPublished = "Plan published. Continue."
    static let resultRecorded = "Result recorded. Explain it briefly to the user."
    static let invalidPlan = "Invalid model plan"
    static let invalidResult = "Invalid task result"
}
