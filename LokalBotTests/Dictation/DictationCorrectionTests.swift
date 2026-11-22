import CryptoKit
import XCTest
@testable import LokalBot

final class DictationCorrectionTests: XCTestCase {
    private let everyday: Set<String> = [
        "we", "should", "ask", "about", "the", "rollout", "next", "week", "meet", "on", "send", "it", "to", "today", "monday",
        "right", "write", "please", "call", "me", "later", "there", "their", "is", "a", "new", "build", "of",
    ]

    private func pairs(_ inserted: String, _ field: String) -> [DictationCorrectionPair] {
        DictationCorrection.pairs(inserted: inserted, fieldText: field, isEverydayWord: { self.everyday.contains($0) })
    }

    func testAMisheardTermFixedInPlaceIsLearned() {
        XCTAssertEqual(
            pairs("We should ask Mila about the cooper netties rollout next week.",
                  "Notes so far. We should ask Mila about the Kubernetes rollout next week."),
            [DictationCorrectionPair(heard: "cooper netties", corrected: "Kubernetes")])
        XCTAssertEqual(
            pairs("Send it to Mila Novack today, please.", "Send it to Mila Novak today, please."),
            [DictationCorrectionPair(heard: "Novack", corrected: "Novak")])
    }

    func testTheSameFixTwiceInOneDictationCountsOnce() {
        XCTAssertEqual(
            pairs("Send it to Novack today and ask Novack about the rollout next week.",
                  "Send it to Novak today and ask Novak about the rollout next week."),
            [DictationCorrectionPair(heard: "Novack", corrected: "Novak")],
            "one dictation is one fix, so it can't turn into an automatic swap by itself")
    }

    func testEditsThatAreNotMishearingsAreIgnored() {
        XCTAssertEqual(pairs("Send it to mila today please", "Send it to Mila today, please."), [], "case only")
        XCTAssertEqual(pairs("We meet on Monday next week", "We meet on Friday next week"), [], "a different word, not a sound-alike")
        XCTAssertEqual(pairs("Call me later there is a new build", "Call me later their is a new build"), [],
                       "an everyday word for another")
        XCTAssertEqual(pairs("We meet at 3 on Monday next week", "We meet at 4 on Monday next week"), [],
                       "digits are the word lock's job")
        XCTAssertEqual(pairs("Send it to Mila today please", "Send it to Mila today please, and copy Jonas as well"), [],
                       "added words are not a correction")
        XCTAssertEqual(pairs("We should ask the house.</li li>One about it", "We should ask the house One about it"), [],
                       "markup is not a word")
    }

    func testAFixOfAnEverydayWordNeverBecomesASwap() {
        XCTAssertEqual(pairs("We meet on Monday next week please", "We meet on Mundi next week please"),
                       [DictationCorrectionPair(heard: "Monday", corrected: "Mundi", swappable: false)])
    }

    func testARewriteTeachesNothing() {
        XCTAssertEqual(pairs("We should ask Mila about the cooper netties rollout next week.",
                             "Let's skip the rollout entirely and talk about it later."), [])
        XCTAssertEqual(pairs("Send it to Mila Novack today, please.", "Something else entirely."), [])
        XCTAssertEqual(pairs("Send Novack", "Send Novak"), [], "too short to place the fix")
    }

    func testSwapsReplaceWholeWordsIgnoringCase() {
        let swaps = [DictationCorrectionPair(heard: "cooper netties", corrected: "Kubernetes"),
                     DictationCorrectionPair(heard: "Novack", corrected: "Novak")]
        let applied = DictationCorrection.apply(swaps, to: "the Cooper Netties cluster and novack, not novacky")
        XCTAssertEqual(applied.text, "the Kubernetes cluster and Novak, not novacky")
        XCTAssertEqual(applied.count, 2)
        XCTAssertEqual(DictationCorrection.apply([], to: "unchanged").text, "unchanged")
    }

    func testTheSpanMustStillBeInTheField() {
        XCTAssertTrue(DictationCorrection.spanFound(inserted: "Send it to Mila Novack today", fieldText: "Hi. Send it to Mila Novak today"))
        XCTAssertFalse(DictationCorrection.spanFound(inserted: "Send it to Mila Novack today", fieldText: "a later paragraph only"))
    }

    func testCorrectedWordsComeFirstInsideTheSameHintLimits() {
        let known = (0..<TranscriptionVocabulary.maximumTerms).map { "Name\($0)" }
        let terms = DictationCorrection.hintTerms(corrected: ["Kubernetes", "name3"], known: known)
        XCTAssertEqual(terms.count, TranscriptionVocabulary.maximumTerms)
        XCTAssertEqual(Array(terms.prefix(3)), ["Kubernetes", "name3", "Name0"])
        XCTAssertFalse(terms.contains("Name3"), "listed once")
        XCTAssertLessThanOrEqual(terms.map { $0.count + 2 }.reduce(0, +), TranscriptionVocabulary.maximumCharacters)
    }

    func testSoundKeyFoldsCommonRespellings() {
        XCTAssertEqual(DictationCorrection.sound("novack"), DictationCorrection.sound("novak"))
        XCTAssertEqual(DictationCorrection.sound("jon"), DictationCorrection.sound("john"))
        XCTAssertNotEqual(DictationCorrection.sound("monday"), DictationCorrection.sound("friday"))
    }
}

@MainActor
final class DictationCorrectionsStoreTests: XCTestCase {
    private var root: URL!
    private let key = SymmetricKey(size: .bits256)
    private var clock = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func store() -> DictationCorrectionsStore {
        DictationCorrectionsStore(storageRoot: root, keyProvider: { [key] in key }, now: { [unowned self] in self.clock })
    }

    func testAFixBecomesASwapOnlyTheSecondTime() {
        let pair = DictationCorrectionPair(heard: "cooper netties", corrected: "Kubernetes")
        let corrections = store()
        corrections.record([pair])
        XCTAssertEqual(corrections.swaps, [])
        XCTAssertEqual(corrections.vocabularyTerms(limit: 10), ["Kubernetes"])
        corrections.record([DictationCorrectionPair(heard: "Cooper Netties", corrected: "Kubernetes")])
        XCTAssertEqual(corrections.swaps, [pair])
        XCTAssertEqual(corrections.corrections.first?.count, 2)
    }

    func testTheFileIsEncryptedAndReadBack() throws {
        store().record([DictationCorrectionPair(heard: "Novack", corrected: "Novak")])
        let raw = try Data(contentsOf: root.appendingPathComponent(DictationCorrectionsStore.fileName))
        XCTAssertNil(String(data: raw, encoding: .utf8).flatMap { $0.contains("Novak") ? $0 : nil })
        let attributes = try FileManager.default.attributesOfItem(
            atPath: root.appendingPathComponent(DictationCorrectionsStore.fileName).path)
        XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o600)
        XCTAssertEqual(store().vocabularyTerms(limit: 5), ["Novak"])
    }

    func testAnEverydayHeardWordOnlyHelpsTheVocabulary() {
        let corrections = store()
        let pair = DictationCorrectionPair(heard: "Monday", corrected: "Mundi", swappable: false)
        corrections.record([pair])
        corrections.record([pair])
        XCTAssertEqual(corrections.swaps, [], "\"Monday\" is never rewritten everywhere")
        XCTAssertEqual(corrections.vocabularyTerms(limit: 5), ["Mundi"])
        XCTAssertEqual(DictationCorrection.apply(corrections.swaps, to: "See you Monday").text, "See you Monday")
    }

    func testTheLatestOfTwoOppositeFixesWins() {
        let corrections = store()
        corrections.record([DictationCorrectionPair(heard: "Ana", corrected: "Anna")])
        corrections.record([DictationCorrectionPair(heard: "Ana", corrected: "Anna")])
        corrections.record([DictationCorrectionPair(heard: "Anna", corrected: "Ana")])
        XCTAssertEqual(corrections.corrections.map(\.corrected), ["Ana"])
        XCTAssertEqual(corrections.swaps, [])
    }

    func testDeleteForgetAndExpiry() {
        let corrections = store()
        corrections.record([DictationCorrectionPair(heard: "Novack", corrected: "Novak"),
                            DictationCorrectionPair(heard: "cooper netties", corrected: "Kubernetes")])
        let first = corrections.corrections[0].id
        corrections.delete(first)
        let reread = store()
        reread.load()
        XCTAssertEqual(reread.corrections.map(\.corrected), ["Kubernetes"])
        clock = clock.addingTimeInterval(DictationCorrectionsStore.retention + 1)
        let later = store()
        later.load()
        XCTAssertEqual(later.corrections, [], "unused for 180 days")
        corrections.forgetAll()
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent(DictationCorrectionsStore.fileName).path))
    }

    func testTheKeychainIsNotTouchedUntilSomethingIsKept() {
        var asked = 0
        let corrections = DictationCorrectionsStore(storageRoot: root, keyProvider: { [key] in asked += 1; return key })
        XCTAssertEqual(corrections.swaps, [])
        XCTAssertEqual(corrections.vocabularyTerms(limit: 3), [])
        XCTAssertEqual(asked, 0)
    }

    func testTheListIsCapped() {
        let corrections = store()
        for index in 0..<(DictationCorrectionsStore.maxEntries + 5) {
            clock = clock.addingTimeInterval(1)
            corrections.record([DictationCorrectionPair(heard: "term\(index)", corrected: "Term\(index)x")])
        }
        XCTAssertEqual(corrections.corrections.count, DictationCorrectionsStore.maxEntries)
        XCTAssertFalse(corrections.corrections.contains { $0.heard == "term0" })
    }
}

final class DictationCorrectionSettingsTests: XCTestCase {
    func testLearningFromCorrectionsIsOffByDefaultAndRoundTrips() throws {
        XCTAssertFalse(AppSettings().dictationLearnFromCorrections)
        var settings = AppSettings()
        settings.dictationLearnFromCorrections = true
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertTrue(decoded.dictationLearnFromCorrections)
        let legacy = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        XCTAssertFalse(legacy.dictationLearnFromCorrections)
    }
}
