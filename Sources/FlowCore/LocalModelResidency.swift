import Foundation

/// Timing rules for keeping a local model in memory.
public struct ResidencyPolicy: Sendable, Equatable {
    /// A loaded model is released after this long without use.
    public var idleTimeout: TimeInterval
    /// How long a transcript may wait for a load already in progress before the
    /// cascade falls through to the next model.
    public var waitBudget: TimeInterval
    /// Load time (weights + kernel warm-up) assumed until one has been measured.
    public var assumedLoadDuration: TimeInterval

    public init(idleTimeout: TimeInterval, waitBudget: TimeInterval, assumedLoadDuration: TimeInterval) {
        self.idleTimeout = idleTimeout
        self.waitBudget = waitBudget
        self.assumedLoadDuration = assumedLoadDuration
    }

    /// ~15 minutes idle. The wait budget roughly matches the sentence latency
    /// target (400 ms) plus slack; a 1.7B load with warm-up takes a few seconds,
    /// so only a load started early in the hold (at key-down) is waited for.
    public static let standard = ResidencyPolicy(idleTimeout: 15 * 60, waitBudget: 0.75, assumedLoadDuration: 4)

    /// The Command Mode model (Qwen 4B). Its load only starts at Shift, often
    /// seconds into the hold, so it is usually still loading at release. Command
    /// Mode has no 400 ms target (generation alone takes a second or more) and
    /// Qwen 4B is the better model, so a load expected to finish within 4 s is
    /// waited for; a longer one (Shift pressed just before release, a cold disk)
    /// falls through to Apple's model. The 4B has ~2.3× the 1.7B's weights
    /// (3.1 s measured), hence ~6 s assumed until this Mac has measured one.
    public static let commandMode = ResidencyPolicy(idleTimeout: 15 * 60, waitBudget: 4, assumedLoadDuration: 6)
}

/// Backoff between attempts of a failed model download (which resumes where it stopped).
public enum DownloadRetry {
    /// 30 s, doubling, capped at 10 minutes.
    public static func delay(afterFailures failures: Int) -> TimeInterval {
        min(30 * pow(2, Double(max(failures, 1) - 1)), 600)
    }
}

/// The order local models download in. Models go in their given order; a
/// failed download waits out its backoff while the others go ahead, so one
/// model that keeps failing never holds up the next.
public struct DownloadQueue<ID: Hashable & Sendable>: Sendable {
    private var pending: [ID]
    private var failures: [ID: Int] = [:]
    private var retryAt: [ID: Date] = [:]

    public init(_ ids: [ID]) { pending = ids }

    /// The download to start next and how long to wait before starting it;
    /// nil once every model is downloaded. Ties go to the earlier model.
    public func next(at now: Date) -> (id: ID, wait: TimeInterval)? {
        let due = pending.enumerated().min { a, b in
            let (ta, tb) = (retryAt[a.element] ?? .distantPast, retryAt[b.element] ?? .distantPast)
            return ta != tb ? ta < tb : a.offset < b.offset
        }
        return due.map { ($0.element, max(0, (retryAt[$0.element] ?? now).timeIntervalSince(now))) }
    }

    public mutating func succeeded(_ id: ID) {
        pending.removeAll { $0 == id }
    }

    public mutating func failed(_ id: ID, at now: Date) {
        failures[id, default: 0] += 1
        retryAt[id] = now.addingTimeInterval(DownloadRetry.delay(afterFailures: failures[id]!))
    }
}

/// Where a local model is in its download → load → unload lifecycle.
public enum LocalModelPhase: Sendable, Equatable {
    case notDownloaded
    case downloading(Double)
    case downloadFailed(String)
    /// On disk, not in memory.
    case downloaded
    case loading(since: Date)
    case loaded
}

/// Whether a local model can serve a request that arrives now.
public enum LocalModelReadiness: Sendable, Equatable {
    case ready
    /// A load is in progress and should finish within the budget: wait for it,
    /// but no longer than this many seconds (`.infinity`: until it ends).
    case wait(upTo: TimeInterval)
    /// Fall through to the next model in the cascade.
    case unavailable
}

/// The residency state of one local model and the decisions derived from it.
/// A value type the app's model manager mutates as downloads, loads and
/// generations happen; the timing rules live here so they can be tested.
public struct LocalModelResidency: Sendable, Equatable {
    public let policy: ResidencyPolicy
    public private(set) var phase: LocalModelPhase = .notDownloaded
    /// Measured duration of the last successful load.
    public private(set) var lastLoadDuration: TimeInterval?
    private var lastUsed: Date?
    private var generationsInFlight = 0

    public init(policy: ResidencyPolicy = .standard) {
        self.policy = policy
    }

    // MARK: Events

    public mutating func downloadProgressed(_ fraction: Double) {
        phase = .downloading(fraction)
    }

    public mutating func downloadFinished() {
        phase = .downloaded
    }

    public mutating func downloadFailed(_ message: String) {
        phase = .downloadFailed(message)
    }

    public mutating func loadStarted(at time: Date) {
        phase = .loading(since: time)
    }

    public mutating func loadFinished(at time: Date) {
        if case .loading(let since) = phase { lastLoadDuration = time.timeIntervalSince(since) }
        phase = .loaded
        lastUsed = time
    }

    public mutating func loadFailed() {
        phase = .downloaded
    }

    public mutating func unloaded() {
        phase = .downloaded
        lastUsed = nil
    }

    public mutating func useBegan() {
        generationsInFlight += 1
    }

    public mutating func useEnded(at time: Date) {
        generationsInFlight = max(0, generationsInFlight - 1)
        lastUsed = time
    }

    // MARK: Decisions

    /// True when the model is on disk and neither loading nor loaded.
    public var canLoad: Bool { phase == .downloaded }

    /// `lastResort`: no other model could take over, so a load in progress is
    /// waited out however long it takes rather than giving up after the budget.
    /// A model that isn't on disk is unavailable either way.
    public func readiness(at now: Date, lastResort: Bool = false) -> LocalModelReadiness {
        switch phase {
        case .loaded:
            return .ready
        case .loading where lastResort:
            return .wait(upTo: .infinity)
        case .loading(let since):
            let expected = lastLoadDuration ?? policy.assumedLoadDuration
            let remaining = since.addingTimeInterval(expected).timeIntervalSince(now)
            return remaining <= policy.waitBudget ? .wait(upTo: policy.waitBudget) : .unavailable
        case .notDownloaded, .downloading, .downloadFailed, .downloaded:
            return .unavailable
        }
    }

    /// When the idle unload is due; nil when not loaded or while generating.
    public var unloadDue: Date? {
        guard phase == .loaded, generationsInFlight == 0, let lastUsed else { return nil }
        return lastUsed.addingTimeInterval(policy.idleTimeout)
    }

    public func shouldUnload(at now: Date) -> Bool {
        unloadDue.map { now >= $0 } ?? false
    }
}
