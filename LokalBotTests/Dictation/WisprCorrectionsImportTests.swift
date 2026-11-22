import CryptoKit
import SQLite3
import XCTest
@testable import LokalBot

@MainActor
final class WisprCorrectionsImportTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let day: TimeInterval = 24 * 60 * 60

    private func edit(_ pasted: String, _ edited: String, daysAgo: Double?, app: String? = "com.example.notes",
                      url: String? = nil) -> WisprFlowLibrary.DictationEdit {
        WisprFlowLibrary.DictationEdit(pasted: pasted, edited: edited, bundleID: app, pageURL: url,
                                       date: daysAgo.map { now.addingTimeInterval(-$0 * day) })
    }

    private func plan(_ edits: [WisprFlowLibrary.DictationEdit],
                      permits: (WisprFlowLibrary.DictationEdit) -> Bool = { _ in true }) -> WisprCorrectionsImport.Plan {
        WisprCorrectionsImport.plan(edits, now: now, permits: permits,
                                    isEverydayWord: { DictationCorrection.isEverydayEnglishWord($0) })
    }

    func testFixesAreFoundOldestFirstAndCounted() {
        let result = plan([
            edit("send it to cooper netties today", "send it to Kubernetes today", daysAgo: 3),
            edit("the call with Novack is at noon", "the call with Novak is at noon", daysAgo: 10),
            edit("we moved cooper netties to the new cluster", "we moved Kubernetes to the new cluster", daysAgo: 1),
            edit("please write a longer summary here", "Please write a much longer summary of this meeting here.",
                 daysAgo: 2),
        ])
        XCTAssertEqual(result.editedDictations, 4)
        XCTAssertEqual(result.dictationsWithFixes, 3)
        XCTAssertEqual(result.fixes.map(\.pair.corrected), ["Novak", "Kubernetes", "Kubernetes"])
        XCTAssertEqual(result.distinctPairs, 2)
        XCTAssertEqual(result.automaticPairs, 1, "only the fix made twice becomes automatic")
    }

    func testOldUndatedAndExcludedDictationsAreLeftOut() {
        let result = plan([
            edit("send it to cooper netties today", "send it to Kubernetes today", daysAgo: 200),
            edit("send it to cooper netties today", "send it to Kubernetes today", daysAgo: nil),
            edit("send it to cooper netties today", "send it to Kubernetes today", daysAgo: 5, app: "com.example.secret"),
        ], permits: { $0.bundleID != "com.example.secret" })
        XCTAssertEqual(result.olderOrUndated, 2)
        XCTAssertEqual(result.excluded, 1)
        XCTAssertEqual(result.fixes, [])
    }

    func testTheSharedExclusionsApplyToImportedDictations() {
        let notes = edit("a b c", "a b d", daysAgo: 1)
        XCTAssertTrue(WisprCorrectionsImport.permits(notes, appName: "Notes", excludedApps: [], excludedDomains: []))
        XCTAssertFalse(WisprCorrectionsImport.permits(notes, appName: "Notes", excludedApps: ["Notes"], excludedDomains: []))
        XCTAssertFalse(WisprCorrectionsImport.permits(notes, appName: "Notes", excludedApps: ["com.example.notes"],
                                                      excludedDomains: []))
        let page = edit("a b c", "a b d", daysAgo: 1, app: "com.apple.Safari", url: "https://mail.example.com/inbox")
        XCTAssertTrue(WisprCorrectionsImport.permits(page, appName: "Safari", excludedApps: [], excludedDomains: []))
        XCTAssertFalse(WisprCorrectionsImport.permits(page, appName: "Safari", excludedApps: [],
                                                      excludedDomains: ["mail.example.com"]))
        let host = edit("a b c", "a b d", daysAgo: 1, app: "com.google.Chrome",
                        url: WisprFlowLibrary.pageAddress("docs.example.com"))
        XCTAssertTrue(WisprCorrectionsImport.permits(host, appName: "Google Chrome", excludedApps: [], excludedDomains: []))
        XCTAssertFalse(WisprCorrectionsImport.permits(host, appName: "Google Chrome", excludedApps: [],
                                                      excludedDomains: ["docs.example.com"]))
        let unknownPage = edit("a b c", "a b d", daysAgo: 1, app: "com.apple.Safari")
        XCTAssertFalse(WisprCorrectionsImport.permits(unknownPage, appName: "Safari", excludedApps: [], excludedDomains: []),
                       "a browser dictation without its page is skipped, as when dictating live")
    }
}

@MainActor
final class DictationCorrectionsStoreImportTests: XCTestCase {
    private var root: URL!
    private let key = SymmetricKey(size: .bits256)
    private var clock = Date(timeIntervalSince1970: 1_800_000_000)
    private let day: TimeInterval = 24 * 60 * 60

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func store() -> DictationCorrectionsStore {
        DictationCorrectionsStore(storageRoot: root, keyProvider: { [key] in key }, now: { [unowned self] in self.clock })
    }

    private func daysAgo(_ days: Double) -> Date { clock.addingTimeInterval(-days * day) }

    func testEarlierFixesKeepTheirDatesAndImportingTwiceCountsNothingNew() {
        let pair = DictationCorrectionPair(heard: "cooper netties", corrected: "Kubernetes")
        let corrections = store()
        XCTAssertEqual(corrections.recordEarlier([(pair: pair, date: daysAgo(3)), (pair: pair, date: daysAgo(9))]), 2)
        XCTAssertEqual(corrections.corrections.first?.count, 2)
        XCTAssertEqual(corrections.corrections.first?.firstSeen, daysAgo(9))
        XCTAssertEqual(corrections.corrections.first?.lastSeen, daysAgo(3))
        XCTAssertEqual(corrections.swaps, [pair])
        XCTAssertEqual(corrections.recordEarlier([(pair: pair, date: daysAgo(3)), (pair: pair, date: daysAgo(9))]), 0)
        let reread = store()
        reread.load()
        XCTAssertEqual(reread.corrections.first?.count, 2)
    }

    func testANewerLiveFixBeatsAnOlderOppositeImportedOne() {
        let corrections = store()
        corrections.record([DictationCorrectionPair(heard: "Anna", corrected: "Ana")])
        XCTAssertEqual(corrections.recordEarlier([(pair: DictationCorrectionPair(heard: "Ana", corrected: "Anna"),
                                                   date: daysAgo(20))]), 0)
        XCTAssertEqual(corrections.corrections.map(\.corrected), ["Ana"])
        corrections.recordEarlier([(pair: DictationCorrectionPair(heard: "Novak", corrected: "Novack"), date: daysAgo(30))])
        corrections.record([DictationCorrectionPair(heard: "Novack", corrected: "Novak")])
        XCTAssertEqual(corrections.corrections.map(\.corrected).sorted(), ["Ana", "Novak"])
    }

    func testImportedFixesFollowTheSameExpiry() {
        let corrections = store()
        corrections.recordEarlier([(pair: DictationCorrectionPair(heard: "Novack", corrected: "Novak"),
                                    date: daysAgo(181))])
        XCTAssertEqual(corrections.corrections, [])
    }
}
