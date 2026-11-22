import CryptoKit
import Foundation

struct DictationLearnedCorrection: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var heard: String
    var corrected: String
    var count: Int
    var swappable: Bool
    var firstSeen: Date
    var lastSeen: Date
}

@MainActor
final class DictationCorrectionsStore: ObservableObject {
    static let fileName = "dictation-corrections.enc"
    static let keychainAccount = "dictation-corrections-key"
    nonisolated static let maxEntries = 200
    nonisolated static let retention: TimeInterval = 180 * 24 * 60 * 60
    nonisolated static let swapThreshold = 2

    @Published private(set) var corrections: [DictationLearnedCorrection] = []

    private let url: URL
    private let keyProvider: @MainActor () -> SymmetricKey?
    private let now: @MainActor () -> Date
    private var key: SymmetricKey?
    private var loaded = false

    init(storageRoot: URL,
         keyProvider: @escaping @MainActor () -> SymmetricKey? = {
             try? KeychainSecrets.symmetricKey(account: DictationCorrectionsStore.keychainAccount)
         },
         now: @escaping @MainActor () -> Date = Date.init) {
        url = storageRoot.appendingPathComponent(Self.fileName)
        self.keyProvider = keyProvider
        self.now = now
    }

    var swaps: [DictationCorrectionPair] {
        load()
        let eligible = corrections.filter { $0.swappable && $0.count >= Self.swapThreshold }
        let byHeard = Dictionary(grouping: eligible) { $0.heard.lowercased() }
        return byHeard.values.compactMap { group in
            group.max { ($0.count, $0.lastSeen) < ($1.count, $1.lastSeen) }
        }.map { DictationCorrectionPair(heard: $0.heard, corrected: $0.corrected) }
    }

    func vocabularyTerms(limit: Int) -> [String] {
        load()
        var seen = Set<String>()
        return corrections
            .sorted { ($0.count, $0.lastSeen) > ($1.count, $1.lastSeen) }
            .map(\.corrected)
            .filter { seen.insert($0.lowercased()).inserted }
            .prefix(limit)
            .map { $0 }
    }

    func record(_ pairs: [DictationCorrectionPair]) {
        guard !pairs.isEmpty else { return }
        load()
        let date = now()
        for pair in pairs { add(pair, at: date) }
        prune()
        save()
    }

    @discardableResult
    func recordEarlier(_ seen: [(pair: DictationCorrectionPair, date: Date)]) -> Int {
        guard !seen.isEmpty else { return 0 }
        load()
        var added = 0
        for (pair, date) in seen.sorted(by: { $0.date < $1.date }) {
            guard !corrections.contains(where: { Self.isOpposite($0, pair) && $0.lastSeen >= date }),
                  !corrections.contains(where: { Self.isSame($0, pair) && $0.lastSeen >= date }) else { continue }
            add(pair, at: date)
            added += 1
        }
        prune()
        save()
        return added
    }

    private func add(_ pair: DictationCorrectionPair, at date: Date) {
        corrections.removeAll { Self.isOpposite($0, pair) }
        if let index = corrections.firstIndex(where: { Self.isSame($0, pair) }) {
            corrections[index].count += 1
            corrections[index].swappable = pair.swappable
            corrections[index].lastSeen = date
        } else {
            corrections.append(DictationLearnedCorrection(
                id: UUID(), heard: pair.heard, corrected: pair.corrected, count: 1, swappable: pair.swappable,
                firstSeen: date, lastSeen: date))
        }
    }

    private static func isSame(_ correction: DictationLearnedCorrection, _ pair: DictationCorrectionPair) -> Bool {
        correction.heard.lowercased() == pair.heard.lowercased() && correction.corrected == pair.corrected
    }

    private static func isOpposite(_ correction: DictationLearnedCorrection, _ pair: DictationCorrectionPair) -> Bool {
        correction.heard.lowercased() == pair.corrected.lowercased()
            && correction.corrected.lowercased() == pair.heard.lowercased()
    }

    func delete(_ id: UUID) {
        load()
        corrections.removeAll { $0.id == id }
        save()
    }

    func forgetAll() {
        corrections = []
        loaded = true
        try? FileManager.default.removeItem(at: url)
    }

    func load() {
        guard !loaded else { return }
        loaded = true
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        key = keyProvider()
        guard let key, let encrypted = try? Data(contentsOf: url),
              let sealed = try? AES.GCM.SealedBox(combined: encrypted),
              let data = try? AES.GCM.open(sealed, using: key),
              let stored = try? JSONDecoder().decode([DictationLearnedCorrection].self, from: data) else { return }
        corrections = stored
        let before = corrections.count
        prune()
        if corrections.count != before { save() }
    }

    private func prune() {
        let cutoff = now().addingTimeInterval(-Self.retention)
        corrections.removeAll { $0.lastSeen < cutoff }
        if corrections.count > Self.maxEntries {
            corrections = Array(corrections.sorted { $0.lastSeen > $1.lastSeen }.prefix(Self.maxEntries))
        }
    }

    private func save() {
        guard !corrections.isEmpty else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        if key == nil { key = keyProvider() }
        guard let key, let data = try? JSONEncoder().encode(corrections),
              let sealed = try? AES.GCM.seal(data, using: key).combined else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try sealed.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            lokalbotLog("dictation corrections not saved: \(error.localizedDescription)")
        }
    }
}
