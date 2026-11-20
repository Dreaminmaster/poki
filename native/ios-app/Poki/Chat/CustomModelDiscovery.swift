import Foundation
import Observation

/// A form's temporary model list. No account state is written until the owner saves the form.
@MainActor @Observable
final class CustomModelDiscovery {
    private(set) var loading = false
    private(set) var models: [String] = []
    private(set) var problem: ModelCatalog.DiscoveryError?
    var presenting = false
    private var generation = 0
    private var task: Task<Void, Never>?

    func cancel() {
        generation += 1
        task?.cancel()
        task = nil
        loading = false
    }

    func reset() {
        cancel()
        models = []
        problem = nil
        presenting = false
    }

    func fetch(address: String, key: String?, session: URLSession = .shared) {
        reset()
        loading = true
        let current = generation
        task = Task { [weak self] in
            do {
                let models = try await ModelCatalog.fetchCustom(address: address, key: key, session: session)
                guard let self, self.generation == current else { return }
                self.models = models
                self.loading = false
                self.presenting = true
                self.task = nil
            } catch {
                guard let self, self.generation == current else { return }
                self.loading = false
                if !(error is CancellationError) {
                    self.problem = (error as? ModelCatalog.DiscoveryError) ?? .network
                }
                self.task = nil
            }
        }
    }
}
