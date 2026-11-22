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
}
