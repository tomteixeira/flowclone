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

final class DownloadQueueTests: XCTestCase {
    private let t0 = Date(timeIntervalSinceReferenceDate: 0)

    func testDownloadsInOrder() {
        var queue = DownloadQueue(["1.7b", "4b"])
        XCTAssertEqual(queue.next(at: t0)?.id, "1.7b")
        queue.succeeded("1.7b")
        XCTAssertEqual(queue.next(at: t0)?.id, "4b")
        queue.succeeded("4b")
        XCTAssertNil(queue.next(at: t0))
    }

    func testAFailingModelDoesNotStarveTheNext() {
        var queue = DownloadQueue(["1.7b", "4b"])
        queue.failed("1.7b", at: t0)
        let next = queue.next(at: t0)
        XCTAssertEqual(next?.id, "4b")
        XCTAssertEqual(next?.wait, 0)
    }

    func testAFailedModelIsRetriedAfterItsBackoff() {
        var queue = DownloadQueue(["1.7b", "4b"])
        queue.failed("1.7b", at: t0)
        queue.succeeded("4b")
        let retry = queue.next(at: t0.addingTimeInterval(10))
        XCTAssertEqual(retry?.id, "1.7b")
        XCTAssertEqual(retry?.wait, 20)
    }

    func testWhenEveryModelFailedTheEarliestRetryGoesFirst() {
        var queue = DownloadQueue(["1.7b", "4b"])
        queue.failed("1.7b", at: t0)
        queue.failed("1.7b", at: t0.addingTimeInterval(30)) // retry due at 30 + 60
        queue.failed("4b", at: t0.addingTimeInterval(31))   // retry due at 31 + 30
        XCTAssertEqual(queue.next(at: t0.addingTimeInterval(31))?.id, "4b")
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

final class CommandModeResidencyTests: XCTestCase {
    private let shift = Date(timeIntervalSinceReferenceDate: 0)

    private func loadingSinceShift() -> LocalModelResidency {
        var residency = LocalModelResidency(policy: .commandMode)
        residency.downloadFinished()
        residency.loadStarted(at: shift)
        return residency
    }

    func testALoadStartedAtShiftAFewSecondsBeforeReleaseIsWaitedFor() {
        // Shift, then ~2.5 s of instruction and transcription: the 4B is still loading.
        XCTAssertEqual(loadingSinceShift().readiness(at: shift.addingTimeInterval(2.5)), .wait(upTo: 4))
    }

    func testALoadStartedJustBeforeReleaseFallsThroughToApple() {
        XCTAssertEqual(loadingSinceShift().readiness(at: shift.addingTimeInterval(0.5)), .unavailable)
    }

    func testWithNothingToFallBackOnALongLoadIsWaitedOut() {
        XCTAssertEqual(loadingSinceShift().readiness(at: shift.addingTimeInterval(0.5), lastResort: true),
                       .wait(upTo: .infinity))
    }

    func testWithNothingToFallBackOnAModelNotOnDiskStillFailsFast() {
        var residency = LocalModelResidency(policy: .commandMode)
        XCTAssertEqual(residency.readiness(at: shift, lastResort: true), .unavailable)
        residency.downloadProgressed(0.5)
        XCTAssertEqual(residency.readiness(at: shift, lastResort: true), .unavailable)
    }

    func testTheFourBUnloadsAfterFifteenIdleMinutes() {
        var residency = loadingSinceShift()
        residency.loadFinished(at: shift.addingTimeInterval(6))
        XCTAssertFalse(residency.shouldUnload(at: shift.addingTimeInterval(6 + 899)))
        XCTAssertTrue(residency.shouldUnload(at: shift.addingTimeInterval(6 + 900)))
    }
}

final class LocalModelPlanTests: XCTestCase {
    func testThe4BDownloadsAfterThe1_7B() {
        XCTAssertEqual(LocalModelPlan(override: nil).downloads, [LocalModels.formatting, LocalModels.commandMode])
    }

    func testDictationLoadsOnlyThe1_7BAndCommandModeOnlyThe4B() {
        let plan = LocalModelPlan(override: nil)
        XCTAssertEqual(plan.model(for: .dictation), LocalModels.formatting)
        XCTAssertEqual(plan.model(for: .command), LocalModels.commandMode)
    }

    func testThe4BGetsTheCommandModeWaitBudget() {
        let plan = LocalModelPlan(override: nil)
        XCTAssertEqual(plan.policy(for: LocalModels.commandMode), .commandMode)
        XCTAssertEqual(plan.policy(for: LocalModels.formatting), .standard)
    }

    func testAModelForcedForBothTasksKeepsTheFormattingBudget() {
        let plan = LocalModelPlan(override: .local(LocalModels.formatting))
        XCTAssertEqual(plan.downloads, [LocalModels.formatting])
        XCTAssertEqual(plan.model(for: .command), LocalModels.formatting)
        XCTAssertEqual(plan.policy(for: LocalModels.formatting), .standard)
    }

    func testAppleOrOffOverridesManageNoLocalModel() {
        XCTAssertEqual(LocalModelPlan(override: .apple).downloads, [])
        XCTAssertNil(LocalModelPlan(override: .off).model(for: .command))
    }

    func testCommandModeTriesQwenThenApple() {
        let qwen = FakeTextModel("qwen", reply: .text("x"))
        let apple = FakeTextModel("apple", reply: .text("x"))
        XCTAssertEqual(LocalModelPlan(override: nil).commandCandidates(local: qwen, apple: apple).map(\.id), ["qwen", "apple"])
        XCTAssertEqual(LocalModelPlan(override: nil).commandCandidates(local: nil, apple: apple).map(\.id), ["apple"])
    }

    func testFormattingFollowsTheSettingWithoutOverride() {
        let qwen = FakeTextModel("qwen", reply: .text("x"))
        let apple = FakeTextModel("apple", reply: .text("x"))
        let plan = LocalModelPlan(override: nil)
        XCTAssertEqual(plan.formattingCandidates(engine: .auto, local: qwen, apple: apple).map(\.id), ["apple", "qwen"])
        XCTAssertEqual(plan.formattingCandidates(engine: .apple, local: qwen, apple: apple).map(\.id), ["apple"])
        XCTAssertEqual(plan.formattingCandidates(engine: .off, local: qwen, apple: apple).map(\.id), [])
    }

    func testOverridesForceTheFormattingCascadeWhateverTheSetting() {
        let qwen = FakeTextModel("qwen", reply: .text("x"))
        let apple = FakeTextModel("apple", reply: .text("x"))
        XCTAssertEqual(LocalModelPlan(override: .local(LocalModels.formatting))
            .formattingCandidates(engine: .off, local: qwen, apple: apple).map(\.id), ["qwen"])
        XCTAssertEqual(LocalModelPlan(override: .apple)
            .formattingCandidates(engine: .auto, local: qwen, apple: apple).map(\.id), ["apple"])
        XCTAssertEqual(LocalModelPlan(override: .off)
            .formattingCandidates(engine: .auto, local: qwen, apple: apple).map(\.id), [])
    }

    func testKeyDownPreloadsTheFormattingModelOnlyWhenTheCascadeWouldReachIt() {
        let plan = LocalModelPlan(override: nil)
        XCTAssertFalse(plan.preloadsFormattingModel(engine: .auto, appleAvailable: true))
        XCTAssertTrue(plan.preloadsFormattingModel(engine: .auto, appleAvailable: false))
        XCTAssertFalse(plan.preloadsFormattingModel(engine: .apple, appleAvailable: false))
        XCTAssertTrue(LocalModelPlan(override: .local(LocalModels.formatting))
            .preloadsFormattingModel(engine: .off, appleAvailable: true))
        XCTAssertFalse(LocalModelPlan(override: .apple).preloadsFormattingModel(engine: .auto, appleAvailable: false))
    }

    func testTheCommandModelIsTheLastResortOnlyWhenAppleCantTakeOver() {
        XCTAssertTrue(LocalModelPlan(override: nil).commandModelIsLastResort(appleAvailable: false))
        XCTAssertFalse(LocalModelPlan(override: nil).commandModelIsLastResort(appleAvailable: true))
        XCTAssertTrue(LocalModelPlan(override: .local(LocalModels.formatting)).commandModelIsLastResort(appleAvailable: true))
        XCTAssertFalse(LocalModelPlan(override: .apple).commandModelIsLastResort(appleAvailable: false))
    }

    func testOverridesForceTheCommandModeCascade() {
        let qwen = FakeTextModel("qwen", reply: .text("x"))
        let apple = FakeTextModel("apple", reply: .text("x"))
        XCTAssertEqual(LocalModelPlan(override: .apple).commandCandidates(local: qwen, apple: apple).map(\.id), ["apple"])
        XCTAssertEqual(LocalModelPlan(override: .off).commandCandidates(local: qwen, apple: apple).map(\.id), [])
        XCTAssertEqual(LocalModelPlan(override: .local(LocalModels.formatting))
            .commandCandidates(local: qwen, apple: apple).map(\.id), ["qwen"])
    }
}
