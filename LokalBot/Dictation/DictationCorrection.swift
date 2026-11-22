import AppKit

struct DictationCorrectionPair: Codable, Equatable, Hashable, Sendable {
    var heard: String
    var corrected: String
    var swappable = true
}

enum DictationCorrection {
    static let readDelaysSeconds: [Double] = [8, 20, 30]
    static let maxPairsPerDictation = 2
    static let maxVocabularyTerms = 15
    static let maxWordsPerSide = 3
    static let minimumKeptShare = 2.0 / 3.0
    static let minimumSoundSimilarity = 0.6

    private struct Word {
        let text: String
        let key: String
    }

    static func pairs(inserted: String, fieldText: String,
                      isEverydayWord: (String) -> Bool) -> [DictationCorrectionPair] {
        let sent = words(inserted)
        let field = words(fieldText)
        guard sent.count >= 3, !field.isEmpty else { return [] }
        let matches = alignment(sent.map(\.key), field.map(\.key))
        guard let first = matches.first, let last = matches.last,
              Double(matches.count) / Double(sent.count) >= minimumKeptShare else { return [] }
        var found: [DictationCorrectionPair] = []
        var previous = first
        for match in matches.dropFirst() {
            defer { previous = match }
            let heard = Array(sent[(previous.0 + 1)..<match.0])
            let written = Array(field[(previous.1 + 1)..<match.1])
            guard !heard.isEmpty, !written.isEmpty else { continue }
            guard heard.count <= maxWordsPerSide, written.count <= maxWordsPerSide else { return [] }
            if let pair = correction(heard: heard, written: written, isEverydayWord: isEverydayWord),
               !found.contains(where: { $0.heard.lowercased() == pair.heard.lowercased() && $0.corrected == pair.corrected }) {
                found.append(pair)
            }
        }
        guard last.0 - first.0 + 1 >= sent.count - 2, found.count <= maxPairsPerDictation else { return [] }
        return found
    }

    static func hintTerms(corrected: [String], known: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        var characters = 0
        for term in corrected + known where seen.insert(term.lowercased()).inserted {
            guard result.count < TranscriptionVocabulary.maximumTerms,
                  characters + term.count + 2 <= TranscriptionVocabulary.maximumCharacters else { break }
            result.append(term)
            characters += term.count + 2
        }
        return result
    }

    static func spanFound(inserted: String, fieldText: String) -> Bool {
        let sent = words(inserted)
        guard !sent.isEmpty else { return false }
        let matches = alignment(sent.map(\.key), words(fieldText).map(\.key))
        return Double(matches.count) / Double(sent.count) >= minimumKeptShare
    }

    static func apply(_ swaps: [DictationCorrectionPair], to text: String) -> (text: String, count: Int) {
        var result = text
        var count = 0
        for swap in swaps.sorted(by: { $0.heard.count > $1.heard.count }) {
            let pattern = "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: swap.heard) + "(?![\\p{L}\\p{N}])"
            guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let range = NSRange(result.startIndex..., in: result)
            let hits = expression.numberOfMatches(in: result, range: range)
            guard hits > 0 else { continue }
            result = expression.stringByReplacingMatches(
                in: result, range: range, withTemplate: NSRegularExpression.escapedTemplate(for: swap.corrected))
            count += hits
        }
        return (result, count)
    }

    @MainActor
    static func isEverydayEnglishWord(_ word: String) -> Bool {
        guard word == word.lowercased() else { return false }
        let checker = NSSpellChecker.shared
        guard checker.availableLanguages.contains(where: { $0.hasPrefix("en") }) else { return false }
        let misspelled = checker.checkSpelling(of: word, startingAt: 0, language: "en", wrap: false,
                                               inSpellDocumentWithTag: 0, wordCount: nil)
        return misspelled.location == NSNotFound
    }

    private static func correction(heard: [Word], written: [Word],
                                   isEverydayWord: (String) -> Bool) -> DictationCorrectionPair? {
        guard (1...maxWordsPerSide).contains(heard.count), (1...maxWordsPerSide).contains(written.count) else { return nil }
        let heardText = heard.map(\.text).joined(separator: " ")
        let writtenText = written.map(\.text).joined(separator: " ")
        guard heard.map(\.key).joined() != written.map(\.key).joined() else { return nil }
        guard !(heardText + writtenText).contains(where: \.isNumber) else { return nil }
        guard (heard + written).allSatisfy({ $0.text.allSatisfy { $0.isLetter || "'’-.".contains($0) } }) else { return nil }
        guard written.contains(where: { !isEverydayWord($0.text) }) else { return nil }
        let heardSound = sound(heard.map(\.key).joined())
        let writtenSound = sound(written.map(\.key).joined())
        let longest = max(heardSound.count, writtenSound.count)
        guard longest > 0,
              1 - Double(distance(heardSound, writtenSound)) / Double(longest) >= minimumSoundSimilarity else { return nil }
        let swappable = heard.contains { !isEverydayWord($0.text.lowercased()) }
        return DictationCorrectionPair(heard: heardText, corrected: writtenText, swappable: swappable)
    }

    private static func words(_ text: String) -> [Word] {
        text.split(whereSeparator: \.isWhitespace).compactMap { raw in
            let trimmed = raw.trimmingCharacters(in: .punctuationCharacters.union(.symbols))
            let key = trimmed.lowercased().filter { $0.isLetter || $0.isNumber }
            return key.isEmpty ? nil : Word(text: trimmed, key: key)
        }
    }

    private static func alignment(_ a: [String], _ b: [String]) -> [(Int, Int)] {
        guard !a.isEmpty, !b.isEmpty else { return [] }
        var table = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                table[i][j] = a[i] == b[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var pairs: [(Int, Int)] = []
        var i = 0, j = 0
        while i < a.count, j < b.count {
            if a[i] == b[j] {
                pairs.append((i, j))
                i += 1
                j += 1
            } else if table[i + 1][j] >= table[i][j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        return pairs
    }

    static func sound(_ key: String) -> String {
        let folded = key.folding(options: [.diacriticInsensitive], locale: nil)
            .replacingOccurrences(of: "ph", with: "f")
            .replacingOccurrences(of: "ck", with: "k")
        var result = ""
        for (index, character) in folded.enumerated() {
            var mapped = character
            switch character {
            case "c", "q": mapped = "k"
            case "z": mapped = "s"
            case "v": mapped = "f"
            default: break
            }
            if index > 0, "aeiouyhw".contains(mapped) { continue }
            if result.last == mapped { continue }
            result.append(mapped)
        }
        return result
    }

    private static func distance(_ lhs: String, _ rhs: String) -> Int {
        let a = Array(lhs), b = Array(rhs)
        guard !a.isEmpty else { return b.count }
        guard !b.isEmpty else { return a.count }
        var previous = Array(0...b.count)
        for (i, x) in a.enumerated() {
            var current = [i + 1]
            for (j, y) in b.enumerated() {
                current.append(min(previous[j + 1] + 1, current[j] + 1, previous[j] + (x == y ? 0 : 1)))
            }
            previous = current
        }
        return previous[b.count]
    }
}
