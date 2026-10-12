import FlowCore
import Foundation

/// Owns the local (MLX) language models in the app: downloads them one after
/// the other at launch (retrying failures), loads one when asked (push-to-talk
/// key-down) and releases each after it sits idle. Every model has its own
/// residency, so formatting and Command Mode models come and go independently;
/// the timing rules live in FlowCore's `LocalModelResidency`.
@MainActor
final class LocalModelManager {
    /// In download order (the formatting model first).
    let models: [MLXTextModel]
    /// Any download, load or unload; for status lines.
    var onChange: (() -> Void)? {
        get { relay.handler }
        set { relay.handler = newValue }
    }

    private let relay = Relay()
    private var started = false
    private var idleTimer: Timer?

    init(specs: [LocalModelSpec], policy: ResidencyPolicy = .standard) {
        var seen = Set<LocalModelSpec>()
        let unique = specs.filter { seen.insert($0).inserted }
        let relay = relay
        models = unique.map { MLXTextModel($0, policy: policy, onChange: { Task { @MainActor in relay.handler?() } }) }
    }

    /// Lets the models, created before `self` exists, reach `onChange`.
    @MainActor private final class Relay {
        var handler: (() -> Void)?
    }

    func model(for spec: LocalModelSpec) -> MLXTextModel? {
        models.first { $0.spec == spec }
    }

    /// Downloads every model in order; a failed download retries with backoff
    /// before moving on, so the first model is never blocked by a later one.
    func start() {
        guard !started else { return }
        started = true
        Task {
            for model in models {
                var failures = 0
                while true {
                    do {
                        try await model.download()
                        log.info("text model downloaded: \(model.id, privacy: .public)")
                        break
                    } catch {
                        failures += 1
                        let delay = DownloadRetry.delay(afterFailures: failures)
                        log.error("text model \(model.id, privacy: .public) download failed (\(failures)): \(error.localizedDescription, privacy: .public); retrying in \(Int(delay))s")
                        try? await Task.sleep(for: .seconds(delay))
                    }
                }
            }
        }
        idleTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.unloadIdleModels() }
        }
    }

    /// Starts loading `spec` in the background if it's on disk and not in memory.
    /// Called on push-to-talk key-down so loading overlaps with the recording.
    func prepare(_ spec: LocalModelSpec) {
        guard let model = model(for: spec), model.state?.canLoad == true else { return }
        Task {
            let started = Date()
            do {
                try await model.load()
                log.info("text model loaded: \(model.id, privacy: .public) in \(Date().timeIntervalSince(started), format: .fixed(precision: 2))s")
            } catch {
                log.error("text model \(model.id, privacy: .public) load failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func unloadIdleModels() async {
        for model in models where await model.unloadIfIdle() {
            log.info("text model unloaded after idle: \(model.id, privacy: .public)")
        }
    }

    /// One line for the menu and the setup window.
    func statusText(for spec: LocalModelSpec, name: String) -> String {
        guard let phase = model(for: spec)?.state?.phase else { return "\(name): not used" }
        return switch phase {
        case .notDownloaded: "\(name): waiting to download"
        case .downloading(let p): "\(name): downloading \(Int(p * 100))% (once)"
        case .downloadFailed(let message): "\(name): download failed (\(message)), retrying"
        case .downloaded: "\(name): ready (loads when you dictate)"
        case .loading: "\(name): loading…"
        case .loaded: "\(name): loaded"
        }
    }
}
