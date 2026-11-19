import XCTest
@testable import Poki

@MainActor
final class CustomModelDiscoveryTests: XCTestCase {
    private let address = "https://model-server.test/v1"
    private let defaultsKeys = ["chat.customURL", "chat.customModel", "chat.provider", "chat.model.custom",
                                "models.listed.custom", "models.enabled.custom", "models.revision.custom"]
    private var savedDefaults: [String: Any] = [:]
    private var savedKey: String?
    private var session: URLSession!

    override func setUp() {
        savedKey = ModelKeys.key(.custom)
        savedDefaults = [:]
        for key in defaultsKeys {
            if let value = UserDefaults.standard.object(forKey: key) { savedDefaults[key] = value }
            UserDefaults.standard.removeObject(forKey: key)
        }
        ModelKeys.remove(.custom)
        ModelServerStub.clear()
        URLProtocol.registerClass(ModelServerStub.self)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ModelServerStub.self]
        session = URLSession(configuration: configuration)
    }

    override func tearDown() {
        session.invalidateAndCancel()
        URLProtocol.unregisterClass(ModelServerStub.self)
        ModelServerStub.clear()
        if let savedKey { try? ModelKeys.save(savedKey, for: .custom) } else { ModelKeys.remove(.custom) }
        for key in defaultsKeys {
            if let value = savedDefaults[key] { UserDefaults.standard.set(value, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
    }

    func testRequestPreservesBasePathAndOptionalAuthentication() throws {
        for base in [address, address + "/", "  " + address + "/\n"] {
            let request = try ModelCatalog.customRequest(address: base, key: " test-key ")
            XCTAssertEqual(request.url?.absoluteString, address + "/models")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
            XCTAssertEqual(request.timeoutInterval, 15)
            XCTAssertEqual(request.httpMethod, "GET")
        }
        let request = try ModelCatalog.customRequest(address: "http://model-server.test/gateway/api", key: nil)
        XCTAssertEqual(request.url?.path, "/gateway/api/models")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        for invalid in ["", "file:///tmp/models", "https:///", "https://user:secret@example.com/v1", "https://example.com/v1?key=secret"] {
            XCTAssertThrowsError(try ModelCatalog.customRequest(address: invalid, key: nil))
        }
    }

    func testDraftFetchParsesAndDeduplicatesWithoutSaving() async throws {
        ModelServerStub.answer = (200, #"{"data":[{"id":"z-model"},{"id":"fast-mini"},{"id":"z-model"},{"id":" "},{"id":"embedding-model"}]}"#)
        let models = try await ModelCatalog.fetchCustom(address: address, key: nil, session: session)
        XCTAssertEqual(models, ["fast-mini", "z-model"])
        XCTAssertTrue(ModelKeys.customURL.isEmpty)
        XCTAssertTrue(ModelKeys.customModel.isEmpty)
        XCTAssertNil(ModelKeys.key(.custom))
        XCTAssertTrue(ModelCatalog.listed(.custom).isEmpty)
        XCTAssertEqual(ModelServerStub.requests.count, 1)
        XCTAssertTrue(ModelServerStub.requests[0].body.isEmpty)
    }

    func testCompatibleAndEmptyResponses() async throws {
        ModelServerStub.answer = (200, #"{"models":[{"name":"models/custom-chat"},{"id":"other"}]}"#)
        let compatible = try await ModelCatalog.fetchCustom(address: address, key: nil, session: session)
        XCTAssertEqual(compatible, ["custom-chat", "other"])
        ModelServerStub.answer = (200, #"{"data":[]}"#)
        let empty = try await ModelCatalog.fetchCustom(address: address, key: nil, session: session)
        XCTAssertEqual(empty, [])
    }

    func testMalformedResponseDoesNotEraseCache() async throws {
        ModelKeys.customURL = address
        UserDefaults.standard.set(["saved-model"], forKey: "models.listed.custom")
        for body in ["not json", "{}", #"{"data":{}}"#, #"{"data":[1]}"#] {
            ModelServerStub.answer = (200, body)
            do {
                _ = try await ModelCatalog.refresh(.custom)
                XCTFail("Malformed response accepted: \(body)")
            } catch { XCTAssertEqual(error as? ModelCatalog.DiscoveryError, .malformed) }
            XCTAssertEqual(ModelCatalog.listed(.custom).map(\.id), ["saved-model"])
        }
    }

    func testHTTPFailuresAndTimeoutAreClassified() async {
        let cases: [(Int, ModelCatalog.DiscoveryError)] = [
            (401, .authentication), (403, .permission), (404, .unsupported),
            (405, .unsupported), (429, .rateLimited), (500, .server)
        ]
        for (status, expected) in cases {
            ModelServerStub.answer = (status, "private upstream response")
            do {
                _ = try await ModelCatalog.fetchCustom(address: address, key: nil, session: session)
                XCTFail("HTTP \(status) accepted")
            } catch { XCTAssertEqual(error as? ModelCatalog.DiscoveryError, expected) }
        }
        ModelServerStub.answer = nil
        do {
            _ = try await ModelCatalog.fetchCustom(address: address, key: nil, session: session)
            XCTFail("Timeout accepted")
        } catch { XCTAssertEqual(error as? ModelCatalog.DiscoveryError, .network) }
    }

    func testAddressChangeDoesNotReuseSavedKeyAndSaveSelectsModel() throws {
        ModelKeys.customURL = address
        try ModelKeys.save("old-test-key", for: .custom)
        XCTAssertEqual(ModelKeys.customDraftKey(address: address + "/", typedKey: ""), "old-test-key")
        let changed = "https://model-server.test/other/v1"
        XCTAssertNil(ModelKeys.customDraftKey(address: changed, typedKey: ""))
        XCTAssertEqual(ModelKeys.customDraftKey(address: changed, typedKey: "new-test-key"), "new-test-key")
        UserDefaults.standard.set(["old-model"], forKey: "models.listed.custom")
        UserDefaults.standard.set(["old-model"], forKey: "models.enabled.custom")
        try ModelKeys.saveCustom(address: changed, model: "chosen-model", typedKey: "")
        XCTAssertNil(ModelKeys.key(.custom))
        XCTAssertTrue(ModelCatalog.listed(.custom).isEmpty)
        XCTAssertEqual(ModelKeys.selectedProvider, .custom)
        XCTAssertEqual(ModelKeys.selectedModel, "chosen-model")
        XCTAssertTrue(ModelCatalog.enabled(.custom).contains("chosen-model"))
    }

    func testSavingUnchangedKeylessServicePreservesItsList() throws {
        ModelKeys.customURL = address
        UserDefaults.standard.set(["saved-model"], forKey: "models.listed.custom")
        try ModelKeys.saveCustom(address: address + "/", model: "saved-model", typedKey: "")
        XCTAssertNil(ModelKeys.key(.custom))
        XCTAssertEqual(ModelCatalog.listed(.custom).map(\.id), ["saved-model"])
        XCTAssertEqual(ModelKeys.selectedModel, "saved-model")
    }

    func testReplacingKeyInvalidatesCacheButUnchangedKeyDoesNot() throws {
        ModelKeys.customURL = address
        try ModelKeys.save("old-test-key", for: .custom)
        UserDefaults.standard.set(["saved-model"], forKey: "models.listed.custom")
        try ModelKeys.saveCustom(address: address, model: "saved-model", typedKey: "")
        XCTAssertEqual(ModelCatalog.listed(.custom).map(\.id), ["saved-model"])
        try ModelKeys.saveCustom(address: address, model: "new-model", typedKey: "new-test-key")
        XCTAssertTrue(ModelCatalog.listed(.custom).isEmpty)
        XCTAssertEqual(ModelKeys.selectedModel, "new-model")
    }

    func testChangedConfigurationRejectsInFlightRefresh() async throws {
        ModelKeys.customURL = address
        ModelServerStub.responder = { _, _ in
            // Even an address changed away and back must invalidate the response.
            ModelCatalog.invalidateCustom()
            return (200, "application/json", #"{"data":[{"id":"stale-model"}]}"#)
        }
        do {
            _ = try await ModelCatalog.refresh(.custom)
            XCTFail("Stale response accepted")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(ModelCatalog.listed(.custom).isEmpty)
    }

    func testResetRejectsAnInFlightDraftResponse() async throws {
        let started = expectation(description: "Request reached the server")
        let release = DispatchSemaphore(value: 0)
        ModelServerStub.responder = { _, _ in
            started.fulfill()
            _ = release.wait(timeout: .now() + 3)
            return (200, "application/json", #"{"data":[{"id":"stale-model"}]}"#)
        }
        let discovery = CustomModelDiscovery()
        discovery.fetch(address: address, key: nil, session: session)
        await fulfillment(of: [started], timeout: 2)
        discovery.reset()
        release.signal()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(discovery.loading)
        XCTAssertFalse(discovery.presenting)
        XCTAssertTrue(discovery.models.isEmpty)
        XCTAssertNil(discovery.problem)
    }

    func testResetCancelsDraftAndRetryCanPresentFreshModels() async throws {
        let discovery = CustomModelDiscovery()
        ModelServerStub.answer = (200, #"{"data":[{"id":"old-model"}]}"#)
        discovery.fetch(address: address, key: nil, session: session)
        discovery.reset()
        XCTAssertFalse(discovery.loading)
        XCTAssertFalse(discovery.presenting)
        ModelServerStub.answer = (200, #"{"data":[{"id":"new-model"}]}"#)
        discovery.fetch(address: address, key: nil, session: session)
        for _ in 0..<100 where discovery.loading { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(discovery.models, ["new-model"])
        XCTAssertTrue(discovery.presenting)
        discovery.reset()
        XCTAssertTrue(discovery.models.isEmpty)
        XCTAssertTrue(ModelKeys.customURL.isEmpty)
    }
}
