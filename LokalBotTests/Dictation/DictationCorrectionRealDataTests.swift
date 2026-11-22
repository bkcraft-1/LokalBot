import CryptoKit
import XCTest
@testable import LokalBot

@MainActor
final class DictationCorrectionRealDataTests: XCTestCase {
    private struct Edit: Decodable {
        let inserted: String
        let field: String
    }

    func testCountsTheCorrectionsFoundInExportedEdits() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let input = environment["LOKALBOT_CORRECTIONS_PAIRS"] else {
            throw XCTSkip("Set LOKALBOT_CORRECTIONS_PAIRS to a JSON list of {inserted, field} edits.")
        }
        let edits = try JSONDecoder().decode([Edit].self, from: Data(contentsOf: URL(fileURLWithPath: input)))
        var found: [[String: String]] = []
        var editsWithPairs = 0
        for edit in edits {
            let pairs = DictationCorrection.pairs(
                inserted: edit.inserted, fieldText: edit.field,
                isEverydayWord: { DictationCorrection.isEverydayEnglishWord($0) })
            if !pairs.isEmpty { editsWithPairs += 1 }
            found += pairs.map { ["heard": $0.heard, "corrected": $0.corrected] }
        }
        if let output = environment["LOKALBOT_CORRECTIONS_OUT"] {
            let summary: [String: Any] = ["edits": edits.count, "editsWithPairs": editsWithPairs, "pairs": found]
            try JSONSerialization.data(withJSONObject: summary).write(to: URL(fileURLWithPath: output))
        }
        print("corrections edits=\(edits.count) withPairs=\(editsWithPairs) pairs=\(found.count)")
    }

    func testCountsWhatAWisprFlowImportWouldAdd() throws {
        guard let database = ProcessInfo.processInfo.environment["LOKALBOT_WISPR_DB"] else {
            throw XCTSkip("Set LOKALBOT_WISPR_DB to a copy of Wispr Flow's flow.sqlite.")
        }
        let edits = try WisprFlowLibrary.dictationEdits(at: URL(fileURLWithPath: database))
        var appNames: [String: String] = [:]
        let plan = WisprCorrectionsImport.plan(edits, now: Date(), permits: { edit in
            let name = appNames[edit.bundleID ?? ""] ?? WisprCorrectionsImport.appName(forBundleID: edit.bundleID)
            appNames[edit.bundleID ?? ""] = name
            return WisprCorrectionsImport.permits(edit, appName: name, excludedApps: [], excludedDomains: [])
        }, isEverydayWord: { DictationCorrection.isEverydayEnglishWord($0) })
        let unfiltered = WisprCorrectionsImport.plan(edits, now: Date(), permits: { _ in true },
                                                     isEverydayWord: { DictationCorrection.isEverydayEnglishWord($0) })
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let key = SymmetricKey(size: .bits256)
        let store = DictationCorrectionsStore(storageRoot: root, keyProvider: { key })
        let added = store.recordEarlier(plan.fixes.map { (pair: $0.pair, date: $0.date) })
        let again = store.recordEarlier(plan.fixes.map { (pair: $0.pair, date: $0.date) })
        let counts = ["edited": plan.editedDictations, "olderOrUndated": plan.olderOrUndated, "excluded": plan.excluded,
                      "withoutExclusionsPairs": unfiltered.distinctPairs,
                      "withFixes": plan.dictationsWithFixes, "fixes": plan.fixes.count, "pairs": plan.distinctPairs,
                      "automatic": plan.automaticPairs, "added": added, "kept": store.corrections.count,
                      "swaps": store.swaps.count, "reimported": again]
        if let output = ProcessInfo.processInfo.environment["LOKALBOT_CORRECTIONS_OUT"] {
            try JSONSerialization.data(withJSONObject: counts, options: [.sortedKeys])
                .write(to: URL(fileURLWithPath: output))
        }
        print("wispr import \(counts.sorted { $0.key < $1.key })")
    }
}
