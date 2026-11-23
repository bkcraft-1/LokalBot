import XCTest
@testable import LokalBot

final class DictationWarmCleanupTests: XCTestCase {
    func testRunsOnlyWhenSwitchedOnForComposeOnTheBuiltInModelWithAFastSpeechModel() {
        var settings = AppSettings()
        settings.dictationIntent = .compose
        settings.summarizerBackend = .builtIn
        settings.transcriptionModel = .parakeetUltra
        XCTAssertTrue(DictationWarmCleanup.applies(settings, enabled: true))
        XCTAssertFalse(DictationWarmCleanup.applies(settings, enabled: false))
        settings.transcriptionModel = .qwenASR17B
        XCTAssertFalse(DictationWarmCleanup.applies(settings, enabled: true), "a slow speech model would transcribe all the time")
        settings.transcriptionModel = .parakeetV2
        settings.dictationIntent = .transcribe
        XCTAssertFalse(DictationWarmCleanup.applies(settings, enabled: true))
        settings.dictationIntent = .compose
        settings.summarizerBackend = .openAICompatible
        XCTAssertFalse(DictationWarmCleanup.applies(settings, enabled: true), "partial speech never leaves the Mac")
    }

    func testCleansNewDirectSpeechOfSomeLength() {
        let speech = "so the plan for tomorrow is simple we start at nine with the design review"
        XCTAssertTrue(DictationWarmCleanup.shouldClean(speech, after: ""))
        XCTAssertFalse(DictationWarmCleanup.shouldClean(speech, after: speech))
        XCTAssertFalse(DictationWarmCleanup.shouldClean("so the plan is simple", after: ""))
        XCTAssertFalse(DictationWarmCleanup.shouldClean(
            "reply to this email and say that the plan for tomorrow is simple and we start at nine", after: ""),
            "a writing request reads context, which a warm-up never does")
    }

    func testLogsAReleaseOnlyWhileAPassIsRunning() {
        XCTAssertNil(DictationWarmCleanup.releaseLogLine(stage: .waiting, passes: 3, elapsed: 4.2))
        XCTAssertEqual(DictationWarmCleanup.releaseLogLine(stage: .cleanup, passes: 3, elapsed: 0.139),
                       "dictation warm cleanup released in flight stage=cleanup after=0.14 completed=3")
        XCTAssertEqual(DictationWarmCleanup.releaseLogLine(stage: .speech, passes: 0, elapsed: 0.3),
                       "dictation warm cleanup released in flight stage=speech after=0.30 completed=0")
    }

    func testTheMainServerSpeculatesOnlyWhenSwitchedOn() {
        XCTAssertEqual(MainLLMRuntimePolicy.serverExtraArguments(warmCleanup: false), ["--cache-ram", "2048", "--reasoning", "on"])
        XCTAssertEqual(MainLLMRuntimePolicy.serverExtraArguments(warmCleanup: true),
                       ["--cache-ram", "2048", "--reasoning", "on", "--spec-type", "ngram-cache"])
    }
}
