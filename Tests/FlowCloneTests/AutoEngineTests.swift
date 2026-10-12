import FlowCore
import XCTest

final class FormattingSettingTests: XCTestCase {
    func testCleanupTurnedOffBecomesOff() {
        XCTAssertEqual(FormattingEngine.fromSettings(stored: nil, legacyCleanup: false), .off)
    }

    func testCleanupOnOrNeverSetBecomesAuto() {
        XCTAssertEqual(FormattingEngine.fromSettings(stored: nil, legacyCleanup: true), .auto)
        XCTAssertEqual(FormattingEngine.fromSettings(stored: nil, legacyCleanup: nil), .auto)
    }

    func testSavedEngineWinsOverTheLegacyToggle() {
        XCTAssertEqual(FormattingEngine.fromSettings(stored: "apple", legacyCleanup: false), .apple)
        XCTAssertEqual(FormattingEngine.fromSettings(stored: "off", legacyCleanup: true), .off)
        XCTAssertEqual(FormattingEngine.fromSettings(stored: "auto", legacyCleanup: false), .auto)
    }

    func testUnknownSavedValueFallsBackToTheMigration() {
        XCTAssertEqual(FormattingEngine.fromSettings(stored: "qwen", legacyCleanup: false), .off)
        XCTAssertEqual(FormattingEngine.fromSettings(stored: "qwen", legacyCleanup: nil), .auto)
    }
}

final class LocalModelPreloadTests: XCTestCase {
    func testLocalFirstAlwaysPreloads() {
        XCTAssertTrue(FormattingEngine.preloadsLocal(order: [.local, .apple], appleAvailable: true))
        XCTAssertTrue(FormattingEngine.preloadsLocal(order: [.local, .apple], appleAvailable: false))
    }

    func testAppleFirstPreloadsOnlyWithoutAppleIntelligence() {
        XCTAssertFalse(FormattingEngine.preloadsLocal(order: [.apple, .local], appleAvailable: true))
        XCTAssertTrue(FormattingEngine.preloadsLocal(order: [.apple, .local], appleAvailable: false))
    }

    func testAppleOnlyAndOffNeverLoadTheLocalModel() {
        XCTAssertFalse(FormattingEngine.apple.preloadsLocal(appleAvailable: false))
        XCTAssertFalse(FormattingEngine.off.preloadsLocal(appleAvailable: false))
    }
}

final class DownloadRetryTests: XCTestCase {
    func testRetriesBackOffAndCapAtTenMinutes() {
        XCTAssertEqual(DownloadRetry.delay(afterFailures: 1), 30)
        XCTAssertEqual(DownloadRetry.delay(afterFailures: 2), 60)
        XCTAssertEqual(DownloadRetry.delay(afterFailures: 3), 120)
        XCTAssertEqual(DownloadRetry.delay(afterFailures: 6), 600)
        XCTAssertEqual(DownloadRetry.delay(afterFailures: 50), 600)
    }
}

final class LocalModelResidencyTests: XCTestCase {
    private let t0 = Date(timeIntervalSinceReferenceDate: 0)
    private let policy = ResidencyPolicy(idleTimeout: 900, waitBudget: 0.75, assumedLoadDuration: 4)

    private func loaded(at time: TimeInterval) -> LocalModelResidency {
        var residency = LocalModelResidency(policy: policy)
        residency.downloadFinished()
        residency.loadStarted(at: t0)
        residency.loadFinished(at: t0.addingTimeInterval(time))
        return residency
    }

    // MARK: Readiness when a transcript arrives

    func testNotDownloadedOrDownloadingIsUnavailable() {
        var residency = LocalModelResidency(policy: policy)
        XCTAssertEqual(residency.readiness(at: t0), .unavailable)
        residency.downloadProgressed(0.4)
        XCTAssertEqual(residency.readiness(at: t0), .unavailable)
        XCTAssertEqual(residency.phase, .downloading(0.4))
    }

    func testDownloadedButNotLoadedIsUnavailable() {
        var residency = LocalModelResidency(policy: policy)
        residency.downloadFinished()
        XCTAssertEqual(residency.readiness(at: t0), .unavailable)
    }

    func testLoadedIsReady() {
        XCTAssertEqual(loaded(at: 2).readiness(at: t0.addingTimeInterval(10)), .ready)
    }

    func testLoadFinishingWithinTheBudgetIsWorthWaitingFor() {
        var residency = LocalModelResidency(policy: policy)
        residency.downloadFinished()
        residency.loadStarted(at: t0)
        // Assumed 4 s load, 3.5 s in: about 0.5 s left.
        XCTAssertEqual(residency.readiness(at: t0.addingTimeInterval(3.5)), .wait(upTo: 0.75))
    }

    func testLoadFarFromDoneFallsThrough() {
        var residency = LocalModelResidency(policy: policy)
        residency.downloadFinished()
        residency.loadStarted(at: t0)
        XCTAssertEqual(residency.readiness(at: t0.addingTimeInterval(1)), .unavailable)
    }

    func testMeasuredLoadTimeReplacesTheAssumption() {
        var residency = loaded(at: 1)  // this Mac loads in 1 s
        residency.unloaded()
        let second = t0.addingTimeInterval(5000)
        residency.loadStarted(at: second)
        XCTAssertEqual(residency.readiness(at: second.addingTimeInterval(0.5)), .wait(upTo: 0.75))
    }

    func testFailedDownloadIsUnavailable() {
        var residency = LocalModelResidency(policy: policy)
        residency.downloadFailed("offline")
        XCTAssertEqual(residency.readiness(at: t0), .unavailable)
        XCTAssertEqual(residency.phase, .downloadFailed("offline"))
    }

    func testFailedLoadGoesBackToDownloaded() {
        var residency = LocalModelResidency(policy: policy)
        residency.downloadFinished()
        residency.loadStarted(at: t0)
        residency.loadFailed()
        XCTAssertEqual(residency.phase, .downloaded)
        XCTAssertTrue(residency.canLoad)
    }

    // MARK: Loading on key-down

    func testOnlyADownloadedIdleModelStartsLoading() {
        var residency = LocalModelResidency(policy: policy)
        XCTAssertFalse(residency.canLoad)
        residency.downloadFinished()
        XCTAssertTrue(residency.canLoad)
        residency.loadStarted(at: t0)
        XCTAssertFalse(residency.canLoad)
        XCTAssertFalse(loaded(at: 1).canLoad)
    }

    // MARK: Idle unload

    func testUnloadsFifteenMinutesAfterLoadingWhenNeverUsed() {
        let residency = loaded(at: 2)
        XCTAssertEqual(residency.unloadDue, t0.addingTimeInterval(902))
        XCTAssertFalse(residency.shouldUnload(at: t0.addingTimeInterval(901)))
        XCTAssertTrue(residency.shouldUnload(at: t0.addingTimeInterval(902)))
    }

    func testEachUseRestartsTheIdleClock() {
        var residency = loaded(at: 2)
        residency.useBegan()
        residency.useEnded(at: t0.addingTimeInterval(600))
        XCTAssertFalse(residency.shouldUnload(at: t0.addingTimeInterval(1000)))
        XCTAssertTrue(residency.shouldUnload(at: t0.addingTimeInterval(1500)))
    }

    func testNeverUnloadsMidGeneration() {
        var residency = loaded(at: 2)
        residency.useBegan()
        XCTAssertNil(residency.unloadDue)
        XCTAssertFalse(residency.shouldUnload(at: t0.addingTimeInterval(10_000)))
    }

    func testAfterUnloadTheNextDictationReloads() {
        var residency = loaded(at: 2)
        residency.unloaded()
        XCTAssertEqual(residency.phase, .downloaded)
        XCTAssertTrue(residency.canLoad)
        XCTAssertNil(residency.unloadDue)
        XCTAssertEqual(residency.readiness(at: t0.addingTimeInterval(2000)), .unavailable)
    }
}
