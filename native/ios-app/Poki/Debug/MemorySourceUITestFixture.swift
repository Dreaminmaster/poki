#if DEBUG
import Foundation
import PokiCore

/// Black-box UI test data. Installed only for the explicit -pokiUITestMemorySource
/// launch argument; never used by release builds or normal app launches.
@MainActor
enum MemorySourceUITestFixture {
    static let sourceID = "poki-uitest-memory-source"
    static let activeID = "poki-uitest-active-chat"
    static let marker = "Synthetic saved source transcript"
    static let draft = "Synthetic unsent composer draft"
    private static var wantsLiveTask: Bool {
        let args = ProcessInfo.processInfo.arguments
        return args.contains("-pokiUITestMemorySource") && args.contains("-pokiUITestLiveTask")
    }

    static func beginActualLiveTaskIfRequested(_ chat: ChatModel) {
        guard wantsLiveTask else { return }
        // This follows the real send path; no synthetic running=true flag.
        // The model request is held by the URLProtocol below.
        chat.send("Synthetic owner task held while reading Memory Source")
    }

    static func installIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains("-pokiUITestMemorySource") else { return }
        let defaults = UserDefaults.standard
        defaults.set("memoryRecent", forKey: "pokiScreen")
        defaults.set(draft, forKey: "pokiDraft")
        defaults.set(FirstRun.Record.done.rawValue, forKey: FirstRun.key)
        defaults.set(true, forKey: SessionStore.archivedEarlierKey)

        // Only the narrow UI scenario needs a genuinely running ChatModel.
        // The intercepted stream leaves its HTTP request open so the saved
        // source must enter a preview instead of replacing the active chat.
        if wantsLiveTask {
            let provider = CustomProviders.upsert(CustomProvider(
                endpoints: [CustomEndpoint(url: "https://model-server.test/v1", api: .chatCompletions)],
                model: "memory-source-live-fixture"
            ))
            ModelKeys.selectedProvider = .custom
            ModelKeys.selectedModel = CustomProviders.choiceID(provider.id, provider.model)
            URLProtocol.registerClass(MemorySourceLiveModelProtocol.self)
        }

        let folder = SessionStore.defaultFolder
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let now = Date()
            let active = SavedSession(
                id: activeID, kind: .poki, title: "Active synthetic chat",
                started: now.addingTimeInterval(-1800), updated: now,
                live: false, outcome: .done,
                entries: [ChatEntry(.you("Active synthetic chat", delivered: true))], calls: []
            )
            let source = SavedSession(
                id: sourceID, kind: .poki, title: "Saved synthetic conversation",
                started: now.addingTimeInterval(-7200), updated: now.addingTimeInterval(-3600),
                live: false, outcome: .done,
                entries: [ChatEntry(.you(marker, delivered: true))], calls: []
            )
            let encoder = JSONEncoder()
            for session in [active, source] {
                try encoder.encode(session).write(
                    to: folder.appendingPathComponent(session.id + ".json"),
                    options: .atomic
                )
            }
            _ = RoutineStore.shared.remember(
                "Synthetic source memory", by: RoutineStore.owner,
                heard: NoteOrigin(session: sourceID, app: nil)
            )
        } catch {
            assertionFailure("Memory source UI fixture failed to seed: \(error)")
        }
    }
}

final class MemorySourceLiveModelProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host() == "model-server.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url,
              let response = HTTPURLResponse(
                  url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                  headerFields: ["Content-Type": "text/event-stream", "Cache-Control": "no-cache"]
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        // Deliberately send neither [DONE] nor didFinishLoading: the active
        // chat really waits on its model request during Memory navigation.
        // Simulator teardown cancels the URLSession request.
    }

    override func stopLoading() {}
}

#endif
