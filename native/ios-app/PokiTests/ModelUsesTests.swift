@testable import Poki
import XCTest

/// The Models page's pickers and the providers' tick lists.
@MainActor
final class ModelUsesTests: XCTestCase {
    private let keys = [
        "custom.providers", "chat.customProvider", "chat.provider", "chat.model.custom", "models.enabled.custom",
        "models.enabled.openai", "models.listed.openai", "decisions.offered.openai", "decisions.offered.custom",
        "senses.model", "local.offered.senses", "local.offered.decision", "quickFixes.choice",
        "quickFixes.account.provider", "quickFixes.account.model",
    ]

    override func setUp() {
        super.setUp()
        keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
    }

    override func tearDown() {
        for provider in CustomProviders.all { CustomProviders.remove(provider.id) }
        keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        super.tearDown()
    }

    func testRecommendedModelsAreTheEverydayOnes() {
        XCTAssertTrue(ModelCatalog.recommended("gpt-6.1-terra"))
        XCTAssertTrue(ModelCatalog.recommended("anthropic/claude-sonnet-5.5"))
        XCTAssertTrue(ModelCatalog.recommended(CustomProviders.choiceID(UUID(), "google/gemini-3.8-flash")))
        XCTAssertFalse(ModelCatalog.recommended("gpt-6.1-sol"))
        XCTAssertFalse(ModelCatalog.recommended("gemini-3.8-flash-preview"))
        XCTAssertFalse(ModelCatalog.recommended("claude-haiku-5-5-20261101"))
    }

    func testListedRecommendedModelsStartTicked() {
        UserDefaults.standard.set(["gpt-6.1-terra-mini", "gpt-6.1-sol"], forKey: "models.listed.openai")
        let on = ModelCatalog.enabled(.openai)
        XCTAssertTrue(on.contains("gpt-6.1-terra"))
        XCTAssertTrue(on.contains("gpt-6.1-terra-mini"))
        XCTAssertFalse(on.contains("gpt-6.1-sol"))
    }

    func testChatPickerHasOneSectionPerCustomProvider() throws {
        let first = CustomProviders.upsert(CustomProvider(name: "One", endpoints: [CustomEndpoint(url: "https://one.test/v1")], model: "a"))
        let second = CustomProviders.upsert(CustomProvider(name: "Two", endpoints: [CustomEndpoint(url: "https://two.test/v1")], model: "b"))
        let groups = ModelPicks.groups(.chat).filter { $0.id.hasPrefix("custom.") }
        XCTAssertEqual(groups.map(\.name), ["One", "Two"])
        XCTAssertEqual(groups.map { $0.items.map(\.name) }, [["a"], ["b"]])

        ModelPicks.pick(.account(.custom, CustomProviders.choiceID(second.id, "b")), for: .chat)
        XCTAssertEqual(ModelKeys.selectedProvider, .custom)
        XCTAssertEqual(CustomProviders.current?.id, second.id)
        XCTAssertEqual(ModelPicks.current(.chat), .account(.custom, CustomProviders.choiceID(second.id, "b")))
        XCTAssertNotEqual(first.id, second.id)
    }

    func testSensesOffersOnlyLocalModels() {
        XCTAssertTrue(ModelPicks.groups(.senses).allSatisfy { $0.id == "local" })
        XCTAssertFalse(ProviderRef.account(.openai).uses.contains(.senses))
        XCTAssertEqual(ProviderRef.local.uses, [.decision, .senses])
        SensesLocalModel.set(nil)
        XCTAssertNil(SensesLocalModel.current)
        XCTAssertEqual(ModelPicks.current(.senses), .off)
    }

    func testLocalIsAlwaysListedFirst() {
        XCTAssertEqual(ProviderRef.all.first, .local)
    }

    func testDecisionPickOnACustomProvider() {
        let custom = CustomProviders.upsert(CustomProvider(name: "One", endpoints: [CustomEndpoint(url: "https://one.test/v1")], model: "fast-flash"))
        let id = CustomProviders.choiceID(custom.id, "fast-flash")
        XCTAssertTrue(DecisionOffers.offered(.custom).contains(id))
        ModelPicks.pick(.account(.custom, id), for: .decision)
        XCTAssertEqual(QuickFixes.choice, .account)
        XCTAssertEqual(ModelPicks.current(.decision), .account(.custom, id))
        DecisionOffers.set(id, on: false, for: .custom)
        XCTAssertEqual(QuickFixes.choice, QuickFixes.Choice.none)
    }
}
