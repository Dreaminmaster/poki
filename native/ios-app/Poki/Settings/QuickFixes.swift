#if canImport(FoundationModels)
import FoundationModels
#endif
import PokiCore
import SwiftUI

/// The decision model: a small, fast model which a routine or a path asks how to go on where it would
/// otherwise stop (a prompt in the way, a button renamed or moved). It is a model on this iPhone
/// (Apple Intelligence or a downloaded model, under Settings › Models › Local Models) or a model of one of the
/// owner's model accounts (under the account, Decisions). There is no other switch: it is in use
/// from the moment it is picked, and only one is in use at a time. An account's call goes from this
/// iPhone straight to its provider, never through Poki's relay, and holds the task's goal and the
/// screen's elements as text: no screenshot, and nothing a password field holds.
enum QuickFixes {
    /// Which model decides.
    enum Choice: Hashable {
        case none
        /// Apple's own model, where Apple Intelligence is on the iPhone.
        case apple
        /// The model downloaded to this iPhone (BacktapeModel).
        case downloaded
        /// A model of one of the owner's model accounts (`accountPick`).
        case account

        var raw: String {
            switch self {
            case .none: "none"
            case .apple: "apple"
            case .downloaded: "downloaded"
            case .account: "account"
            }
        }

        init?(raw: String) {
            switch raw {
            case "none": self = .none
            case "apple": self = .apple
            case "downloaded": self = .downloaded
            case "account": self = .account
            default: return nil
            }
        }
    }

    private static let choiceKey = "quickFixes.choice"

    /// The pick; Off until one is made. A pick from the separate providers' page of an earlier build
    /// (Cloudflare, TypeSafe, a custom address) reads as Off: that page is gone, and its token goes
    /// from the keychain with it.
    static var choice: Choice {
        get {
            guard let raw = UserDefaults.standard.string(forKey: choiceKey) else { return .none }
            if let kept = Choice(raw: raw) { return kept }
            UserDefaults.standard.set(Choice.none.raw, forKey: choiceKey)
            UserDefaults.standard.removeObject(forKey: "quickFixes.settings")
            Keychain.delete("quick-fixes.token")
            return .none
        }
        set {
            UserDefaults.standard.set(newValue.raw, forKey: choiceKey)
            // The Models page and the pages under it show the pick: they redraw on this.
            ModelKeys.saved += 1
        }
    }

    private static let accountProviderKey = "quickFixes.account.provider"
    private static let accountModelKey = "quickFixes.account.model"

    /// The account and its model that decide while the pick is an account's (set on the account's
    /// own page, Settings › Models › the account › Decisions).
    static var accountPick: (provider: ModelProvider, model: String)? {
        guard let raw = UserDefaults.standard.string(forKey: accountProviderKey), let provider = ModelProvider(rawValue: raw),
              let model = UserDefaults.standard.string(forKey: accountModelKey), !model.isEmpty else { return nil }
        return (provider, model)
    }

    /// The model of `provider` that is the decision model now, if one of its models is.
    static func accountModel(_ provider: ModelProvider) -> String? {
        guard choice == .account, let pick = accountPick, pick.provider == provider else { return nil }
        return pick.model
    }

    /// Picks an account's model as the decision model; nil turns it off when this account's was.
    static func pickAccount(_ provider: ModelProvider, model: String?) {
        if let model {
            UserDefaults.standard.set(provider.rawValue, forKey: accountProviderKey)
            UserDefaults.standard.set(model, forKey: accountModelKey)
            choice = .account
        } else if accountModel(provider) != nil {
            choice = .none
        }
    }

    /// The decision model's name, for the In Use card; nil while there is none, or the one picked is
    /// gone (its account deleted, its model removed).
    @MainActor
    static var name: String? {
        switch choice {
        case .none: return nil
        case .apple: return OnDeviceDecisions.appleAvailable ? AppLocalization.text("Apple Intelligence") : nil
        case .downloaded: return OnDeviceDecisions.downloadedName
        case .account:
            guard let pick = accountPick, ModelAccounts.isSetUp(pick.provider) else { return nil }
            return AccountDecisions.name(pick.provider, pick.model)
        }
    }

    /// The decider PokiCore asks, read at each run: nil while the pick is Off or cannot run.
    static var decider: Decider? {
        switch choice {
        case .none: return nil
        case .apple: return OnDeviceDecisions.apple
        case .downloaded: return OnDeviceDecisions.downloaded
        case .account: return accountPick.flatMap { AccountDecisions.decider($0.provider, model: $0.model) }
        }
    }
}

/// The models on this iPhone that can decide: nothing of the task or the screen leaves the phone.
enum OnDeviceDecisions {
    /// Apple's own model, where Apple Intelligence is on the iPhone.
    static var appleAvailable: Bool { BacktapeWriter.apple }

    static var apple: PromptDecider? {
        guard appleAvailable else { return nil }
        return PromptDecider(name: "Apple Intelligence", maxState: 5000) { prompt, instructions in await askApple(prompt, instructions: instructions) }
    }

    /// The downloaded model's name once it is on the phone and can run; nil until then.
    @MainActor
    static var downloadedName: String? {
        BacktapeModel.supported && BacktapeModel.shared.ready ? BacktapeModel.shared.choice.name : nil
    }

    /// The downloaded model as the decider. Its files are checked when it is asked: a model removed
    /// since gives no answer, which is an error and never a guess.
    static var downloaded: PromptDecider? {
        guard BacktapeModel.supported else { return nil }
        return PromptDecider(name: "downloaded model", maxState: 5000, patience: 15) { prompt, instructions in
            await BacktapeModel.shared.respond(to: prompt, instructions: instructions, maxTokens: 160, temperature: 0)
        }
    }

    private static func askApple(_ prompt: String, instructions: String) async -> String? {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            do {
                let session = LanguageModelSession(instructions: instructions)
                return try await session.respond(to: prompt).content
            } catch {
                await AppLog.shared.add("decisions", "Apple Intelligence gave no decision: \(error.localizedDescription)")
                return nil
            }
        }
        #endif
        return nil
    }
}
