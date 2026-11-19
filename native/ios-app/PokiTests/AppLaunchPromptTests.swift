import XCTest
@testable import Poki

/// The chat's model is told the bundle ids of the apps a request names, finds the others with
/// find_app, and the debug file keeps the chat's tasks. A tester's 淘宝 and 美团 tasks (Nov 13 2026)
/// failed with "no app with that bundle id is installed": the model had guessed the ids, and the
/// debug file showed no runs at all.
@MainActor
final class AppLaunchPromptTests: XCTestCase {
    func testNamedAppsReachTheModelWithTheirBundleIDs() async {
        for (request, bundleID) in [
            ("打开淘宝", "com.taobao.taobao4iphone"),
            ("打开美团", "com.meituan.imeituan"),
            ("打开铁路12306", "cn.12306.rails12306"),
            ("打开12306", "cn.12306.rails12306"),
            ("打开12306查询", "cn.12306.rails12306"),
            ("打开 12306 查询", "cn.12306.rails12306"),
        ] {
            let prompt = Harness.instructions(for: request)
            XCTAssertTrue(prompt.contains(bundleID), "\(request): missing \(bundleID)")
        }
        XCTAssertFalse(Harness.instructions(for: "打开美团").contains("com.meituan.itakeaway"))
    }

    func testNumericAliasDoesNotMatchInsideLongerIdentifiers() async {
        for request in ["order a123067 now", "call 9123067", "open notesbook"] {
            XCTAssertTrue(AppIconStore.bundleIDs(namedIn: request).isEmpty, request)
        }
    }

    func testLaunchFailureRequiresHomeScreenSearchBeforeCallingAnAppMissing() async {
        let prompt = Harness.instructions(for: "打开美团")
        XCTAssertTrue(prompt.contains("swipe down on the Home Screen to search"))
        XCTAssertTrue(prompt.contains("Say an app is not installed only after find_app says so"))
    }

    // MARK: The debug file

    /// The files and the index these tests fill, at their real places.
    private func clear() {
        try? FileManager.default.removeItem(at: ChatDebugLog.file)
        try? FileManager.default.removeItem(at: InstalledApps.cacheFile)
        DynamicApps.set([])
    }
    override func setUp() async throws { clear() }
    override func tearDown() async throws { clear() }

    func testTheDebugFileKeepsKindsAndFailureCategoriesOnly() {
        let calls = [
            CallRecord(name: "report_plan", arguments: "{}", answer: "Plan published. Continue.", ms: 2, ok: true),
            CallRecord(name: "do", arguments: #"{"actions":[{"launch":"com.taobao.taobao"}]}"#,
                       answer: "app: Poki\nerror: launch com.taobao.taobao: no app with that bundle id is installed on this device\nelements (3):",
                       ms: 120, ok: false),
            CallRecord(name: "do", arguments: #"{"actions":[{"run":"Order my usual"},{"type":"hello","ref":3},{"key":"return"},{"swipe":"sideways please"},{"finish":true}]}"#,
                       answer: "error: the field holds hello", ms: 80, ok: false),
            CallRecord(name: "do", arguments: #"{"actions":[{"launch":"com.taobao.taobao4iphone"},{"launch":"my.private.note"},{"launch":{"bundle":"com.strava.stravaride"}}]}"#,
                       answer: "app: 淘宝", ms: 300, ok: true),
        ]
        DynamicApps.set([.init(id: "com.strava.stravaride", name: "Strava", user: true)])
        let entry = ChatDebugLog.entry(model: "pi, openai/x", named: ["com.taobao.taobao4iphone"], calls: calls, finished: false, seconds: 4.26)
        XCTAssertEqual(entry.seconds, 4.3)
        XCTAssertEqual(entry.calls[1].actions, ["launch"], "an id no app has is not kept")
        XCTAssertEqual(entry.calls[1].error, "launch_not_installed")
        XCTAssertEqual(entry.calls[2].actions, ["run", "type", "key return", "swipe"], "no routine name, no text, no free-form direction")
        XCTAssertEqual(entry.calls[2].error, "failed")
        XCTAssertEqual(entry.calls[3].actions, ["launch com.taobao.taobao4iphone", "launch", "launch com.strava.stravaride"],
                       "an app Poki lists or the phone has is kept; a made-up dotted string is not")
        // A type with a ref is a type every time, whichever key the dictionary gives first.
        for _ in 0..<200 {
            XCTAssertEqual(ChatDebugLog.actions(#"{"actions":[{"ref":3,"type":"hello"},{"tap":4,"count":2},{"mystery":1}]}"#), ["type", "tap", "other"])
        }
    }

    /// The file keeps the newest 20 tasks: the number is written here, not read from the code.
    func testTheDebugFileKeepsTheNewestTwentyTasks() {
        for index in 1...23 {
            ChatDebugLog.add(ChatDebugLog.entry(model: "pi, openai/x", named: ["com.taobao.taobao4iphone"], calls: [], finished: true, seconds: Double(index)))
        }
        let kept = ChatDebugLog.entries()
        XCTAssertEqual(kept.count, 20)
        XCTAssertEqual(kept.first?.seconds, 4, "the three oldest are gone")
        XCTAssertEqual(kept.last?.seconds, 23)
        guard case .array(let tasks) = ChatDebugLog.json(), case .object(let first)? = tasks.first else { return XCTFail("chat_tasks is a list") }
        XCTAssertEqual(tasks.count, 20)
        XCTAssertEqual(first["named"], .array([.string("com.taobao.taobao4iphone")]))
    }

    /// web_type puts the entered value in its answer's first line (WebTools.after), and the call fails
    /// when the page read after it does. Neither the saved tasks nor the exported file may hold it.
    func testAnEnteredValueNeverReachesTheSavedLogOrTheExport() throws {
        let sentinel = "SENTINEL-\(UUID().uuidString)"
        let calls = [
            CallRecord(name: "web_type", arguments: #"{"ref":"e4","text":"\#(sentinel)"}"#,
                       answer: "Typed into “Search”: \(sentinel).\nThe page did not answer. Read it again with web_read.", ms: 900, ok: false),
            CallRecord(name: "do", arguments: #"{"actions":[{"run":"\#(sentinel)"},{"launch":"\#(sentinel) app"},{"type":"\#(sentinel)"}]}"#,
                       answer: "error: \(sentinel)", ms: 10, ok: false),
            CallRecord(name: "find_app", arguments: #"{"name":"\#(sentinel)"}"#, answer: "no app named \"\(sentinel)\" is installed", ms: 5, ok: true),
        ]
        ChatDebugLog.add(ChatDebugLog.entry(model: "pi, openai/x", named: [], calls: calls, finished: nil, seconds: 1))
        let saved = try String(contentsOf: ChatDebugLog.file, encoding: .utf8)
        XCTAssertFalse(saved.contains(sentinel), saved)
        let exported = String(decoding: ChatDebugLog.exportBundle(), as: UTF8.self)
        XCTAssertTrue(exported.contains("chat_tasks"), exported)
        XCTAssertFalse(exported.contains(sentinel), exported)
        XCTAssertEqual(ChatDebugLog.entries().first?.calls.map(\.actions), [[], ["run", "launch", "type"], []])
    }

    // MARK: find_app

    private let phoneList: [InstalledApps.App] = [
        .init(id: "com.taobao.taobao4iphone", name: "淘宝", bundleName: "Taobao4iPhone"),
        .init(id: "com.meituan.itakeaway", name: "美团外卖", bundleName: "iTakeaway"),
        .init(id: "com.meituan.imeituan", name: "美团", bundleName: "imeituan"),
        .init(id: "com.apple.mobilenotes", name: nil, bundleName: "MobileNotes"),
    ]

    /// A finder whose phone answers with `list` through the same read the signer's answer takes, or
    /// whose phone cannot be reached when `list` is nil. `store` nil is an App Store that did not answer.
    private func finder(list: [InstalledApps.App]?, store: [InstalledApps.StoreApp]? = [], icons: @escaping (String) -> Bool? = { _ in nil }) -> InstalledApps {
        let apps = InstalledApps()
        apps.phone = { list == nil ? nil : [:] }
        apps.call = { _ in try Self.signerAnswer(list ?? []) }
        apps.hasIcon = { icons($0) }
        apps.search = { _ in store }
        return apps
    }

    /// The signer's answer to `apps` as it comes over the bridge: {"v": {"apps": [...]}}.
    static func signerAnswer(_ list: [InstalledApps.App]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["v": ["apps": list.map { app in
            var entry: [String: Any] = ["id": app.id]
            entry["name"] = app.name; entry["bundle_name"] = app.bundleName; entry["type"] = app.type
            return entry
        }]])
    }

    private let xianyu: [InstalledApps.StoreApp] = [.init(id: "com.taobao.fleamarket", name: "闲鱼", url: "https://apps.apple.com/cn/app/id510909506")]

    /// The first app find_app's answer lists: the one the agent is told to launch.
    private func firstListed(_ answer: String) -> String? {
        answer.split(separator: "\n").first { $0.hasPrefix("- ") }.map(String.init)
    }

    func testNamesFindTheInstalledAppExactNameFirst() async {
        let apps = finder(list: phoneList)
        let meituan = await apps.find(name: "美团", purpose: nil).text
        XCTAssertEqual(firstListed(meituan), "- 美团: com.meituan.imeituan (installed)", "美团, ahead of 美团外卖 which holds it")
        XCTAssertTrue(meituan.contains("launch it") && meituan.contains("com.meituan.itakeaway"), meituan)
        let taobao = await apps.find(name: "Taobao", purpose: nil).text
        XCTAssertEqual(firstListed(taobao), "- 淘宝: com.taobao.taobao4iphone (installed)", "KnownApps' English name")
        let notes = await apps.find(name: "Notes", purpose: nil).text
        XCTAssertEqual(firstListed(notes), "- MobileNotes: com.apple.mobilenotes (installed)")
        let none = await apps.find(name: "闲鱼", purpose: nil).text
        XCTAssertNil(firstListed(none), none)
    }

    func testFindAppAnswersTheInstalledID() async {
        let answer = await finder(list: phoneList).find(name: "淘宝", purpose: nil)
        XCTAssertFalse(answer.isError)
        XCTAssertTrue(answer.text.contains("com.taobao.taobao4iphone (installed)"), answer.text)
        XCTAssertTrue(answer.text.contains("launch it"), answer.text)
    }

    /// A name two installed apps share points at neither, in either order of the phone's list.
    func testANameTwoInstalledAppsShareIsNeverPicked() async {
        let one = InstalledApps.App(id: "com.strava.stravaride", name: "Strava", bundleName: nil)
        let two = InstalledApps.App(id: "com.example.strava", name: "Strava", bundleName: nil)
        for list in [[one, two], [two, one]] {
            let answer = await finder(list: list).find(name: "Strava", purpose: nil)
            XCTAssertTrue(answer.text.contains("Do not pick one: ask the owner"), answer.text)
            XCTAssertFalse(answer.text.contains("launch it"), answer.text)
            XCTAssertTrue(answer.text.contains("com.strava.stravaride") && answer.text.contains("com.example.strava"), answer.text)
        }
        // An app Poki lists by that name and another the phone calls the same are two as well: the
        // system's Notes does not win over a second app named Notes.
        let systemNotes = InstalledApps.App(id: "com.apple.mobilenotes", name: "Notes", bundleName: "MobileNotes")
        let otherNotes = InstalledApps.App(id: "com.example.notes", name: "Notes", bundleName: nil)
        for list in [[systemNotes, otherNotes], [otherNotes, systemNotes]] {
            let answer = await finder(list: list).find(name: "Notes", purpose: nil)
            XCTAssertTrue(answer.text.contains("Do not pick one: ask the owner"), answer.text)
            XCTAssertFalse(answer.text.contains("launch it"), answer.text)
            XCTAssertTrue(answer.text.contains("com.apple.mobilenotes") && answer.text.contains("com.example.notes"), answer.text)
        }
        let unique = await finder(list: [one]).find(name: "Strava", purpose: nil)
        XCTAssertTrue(unique.text.contains("launch it"), unique.text)
        // Names that only hold what the owner said are offered, never chosen for them.
        let partial = await finder(list: [.init(id: "com.a.one", name: "Strava Run", bundleName: nil), .init(id: "com.a.two", name: "Strava Ride", bundleName: nil)])
            .find(name: "Strava", purpose: nil)
        XCTAssertTrue(partial.text.contains("when more than one could be, ask the owner which"), partial.text)
    }

    func testAMissingAppComesWithItsAppStoreLink() async {
        let answer = await finder(list: phoneList, store: xianyu).find(name: "闲鱼", purpose: nil)
        XCTAssertTrue(answer.text.contains("NOT installed"), answer.text)
        XCTAssertTrue(answer.text.contains("com.taobao.fleamarket (not installed) https://apps.apple.com/cn/app/id510909506"), answer.text)
    }

    func testTheStoresNameFindsAnInstalledAppThePhoneNamesOtherwise() async {
        let apps = finder(list: [.init(id: "com.meituan.imeituan", name: "Meituan", bundleName: nil)],
                          store: [.init(id: "com.meituan.imeituan", name: "美团-问美团，都安排", url: nil)])
        let answer = await apps.find(name: "问美团", purpose: nil)
        XCTAssertTrue(answer.text.contains("com.meituan.imeituan (installed)"), answer.text)
    }

    /// The installed app may be anywhere in the store's results: each is checked before the list is cut.
    func testAnInstalledAppPastTheStoresThirdResultIsStillFound() async {
        let others = (1...3).map { InstalledApps.StoreApp(id: "com.example.other\($0)", name: "美团 \($0)", url: "https://apps.apple.com/cn/app/id\($0)") }
        let apps = finder(list: [.init(id: "com.meituan.imeituan", name: "Meituan", bundleName: nil)],
                          store: others + [.init(id: "com.meituan.imeituan", name: "美团-问美团，都安排", url: nil)])
        let answer = await apps.find(name: "问美团", purpose: nil)
        XCTAssertTrue(answer.text.contains("com.meituan.imeituan (installed)"), answer.text)
        XCTAssertFalse(answer.text.contains("NOT installed"), answer.text)
    }

    func testAPurposeListsInstalledAppsFirst() async {
        let apps = finder(list: phoneList, store: [.init(id: "com.example.park", name: "ParkMe", url: "https://apps.apple.com/us/app/id1"),
                                                   .init(id: "com.meituan.imeituan", name: "美团", url: "https://apps.apple.com/cn/app/id2")])
        let answer = await apps.find(name: nil, purpose: "parking")
        let lines = answer.text.split(separator: "\n").dropFirst()
        XCTAssertEqual(lines.first.map(String.init), "- 美团: com.meituan.imeituan (installed)")
        XCTAssertEqual(lines.last.map(String.init), "- ParkMe: com.example.park (not installed) https://apps.apple.com/us/app/id1")
    }

    func testWithoutThePhonesListAnIconSaysInstalled() async {
        let answer = await finder(list: nil, icons: { $0 == "com.taobao.taobao4iphone" }).find(name: "淘宝", purpose: nil)
        XCTAssertTrue(answer.text.contains("com.taobao.taobao4iphone (installed)"), answer.text)
        XCTAssertTrue(answer.text.contains("could not be read"), answer.text)
    }

    /// A failed lookup is no evidence: with no list, an App Store match stays unknown and the agent is
    /// sent to the Home Screen search instead of telling the owner the app is missing. A missing icon
    /// (icons off, or iOS's generic picture) is no evidence either.
    func testAnUnreadableListNeverMakesAnAppMissing() async {
        for apps in [finder(list: nil, store: xianyu), finder(list: nil), finder(list: nil, store: xianyu, icons: { _ in false }),
                     finder(list: nil, store: nil)] {
            let answer = await apps.find(name: "闲鱼", purpose: nil)
            XCTAssertFalse(answer.text.contains("NOT installed"), answer.text)
            XCTAssertFalse(answer.text.contains("(not installed)"), answer.text)
            XCTAssertTrue(answer.text.contains("could not tell whether"), answer.text)
            XCTAssertTrue(answer.text.contains("swipe down on the Home Screen to search"), answer.text)
        }
    }

    /// A list that was read once and cannot be read again still says what it holds, and proves nothing
    /// about an app installed since.
    func testAnOldListAfterAFailedRefreshNeverMakesAnAppMissing() async {
        var reads = 0
        var clock = Date(timeIntervalSince1970: 1_000_000)
        let apps = InstalledApps()
        apps.now = { clock }
        apps.phone = { [:] }
        apps.call = { [phoneList] _ in
            reads += 1
            if reads > 1 { throw URLError(.timedOut) }
            return try Self.signerAnswer(phoneList)
        }
        apps.hasIcon = { _ in nil }
        apps.search = { [xianyu] _ in xianyu }
        let fresh = await apps.find(name: "闲鱼", purpose: nil)
        XCTAssertTrue(fresh.text.contains("NOT installed"), "a fresh list settles it: \(fresh.text)")

        clock += 600
        let stale = await apps.find(name: "闲鱼", purpose: nil)
        XCTAssertEqual(reads, 2, "the old list is read again")
        XCTAssertFalse(stale.text.contains("NOT installed"), stale.text)
        XCTAssertFalse(stale.text.contains("(not installed)"), stale.text)
        XCTAssertTrue(stale.text.contains("could not tell whether"), stale.text)
        XCTAssertTrue(stale.text.contains("reading it again failed"), stale.text)
        let held = await apps.find(name: "淘宝", purpose: nil)
        XCTAssertTrue(held.text.contains("com.taobao.taobao4iphone (installed)"), "what the old list holds still counts: \(held.text)")
        let inventory = await apps.list()
        XCTAssertEqual(inventory?.fresh, false)
        XCTAssertEqual(apps.installed("com.taobao.fleamarket", in: inventory), nil)
    }

    /// An App Store that did not answer is not an App Store with no match.
    func testAnAppStoreFailureIsNotNoMatch() async {
        let failed = await finder(list: phoneList, store: nil).find(name: "闲鱼", purpose: nil)
        XCTAssertFalse(failed.text.contains("found none either"), failed.text)
        XCTAssertTrue(failed.text.contains("could not be searched"), failed.text)
        let none = await finder(list: phoneList, store: []).find(name: "闲鱼", purpose: nil)
        XCTAssertTrue(none.text.contains("found none either"), none.text)
        let purpose = await finder(list: phoneList, store: nil).find(name: nil, purpose: "parking")
        XCTAssertTrue(purpose.text.contains("could not search the App Store"), purpose.text)
        XCTAssertNil(AppStoreSearch.parse(Data("<html>".utf8)), "an answer that is not the search's JSON is a failure")
        XCTAssertEqual(AppStoreSearch.parse(Data(#"{"resultCount":0,"results":[]}"#.utf8)), [])
    }

    func testTheStoreSearchReadsPastControlCharacters() {
        let body = "{\"resultCount\":1,\"results\":[{\"bundleId\":\"com.taobao.taobao4iphone\",\"trackName\":\"淘宝\",\"trackViewUrl\":\"https://apps.apple.com/cn/app/id387682726?uo=4\",\"description\":\"line one\nline two\"}]}"
        XCTAssertEqual(AppStoreSearch.parse(Data(body.utf8)), [.init(id: "com.taobao.taobao4iphone", name: "淘宝", url: "https://apps.apple.com/cn/app/id387682726")])
    }

    func testTheModelIsOfferedFindApp() {
        XCTAssertTrue(Harness.tools.contains { $0.name == "find_app" })
        XCTAssertTrue(Harness.instructions(for: "打开闲鱼").contains("find_app"))
    }
}
