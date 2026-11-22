import AppKit

enum WisprCorrectionsImport {
    struct Fix: Equatable, Sendable {
        var pair: DictationCorrectionPair
        var date: Date
    }

    struct Plan: Equatable, Sendable {
        var fixes: [Fix] = []
        var editedDictations = 0
        var dictationsWithFixes = 0
        var excluded = 0
        var olderOrUndated = 0

        var distinctPairs: Int {
            Set(fixes.map { Self.key($0.pair) }).count
        }

        var automaticPairs: Int {
            let swappable = fixes.filter(\.pair.swappable)
            return Dictionary(grouping: swappable) { Self.key($0.pair) }.values
                .filter { $0.count >= DictationCorrectionsStore.swapThreshold }.count
        }

        private static func key(_ pair: DictationCorrectionPair) -> String {
            pair.heard.lowercased() + "\u{1F}" + pair.corrected
        }
    }

    static func plan(
        _ edits: [WisprFlowLibrary.DictationEdit],
        now: Date,
        permits: (WisprFlowLibrary.DictationEdit) -> Bool,
        isEverydayWord: (String) -> Bool
    ) -> Plan {
        var plan = Plan()
        let cutoff = now.addingTimeInterval(-DictationCorrectionsStore.retention)
        for edit in edits {
            plan.editedDictations += 1
            guard let date = edit.date, date >= cutoff, date <= now else {
                plan.olderOrUndated += 1
                continue
            }
            guard permits(edit) else {
                plan.excluded += 1
                continue
            }
            let pairs = DictationCorrection.pairs(inserted: edit.pasted, fieldText: edit.edited, isEverydayWord: isEverydayWord)
            guard !pairs.isEmpty else { continue }
            plan.dictationsWithFixes += 1
            plan.fixes += pairs.map { Fix(pair: $0, date: date) }
        }
        plan.fixes.sort { $0.date < $1.date }
        return plan
    }

    static func permits(_ edit: WisprFlowLibrary.DictationEdit, appName: String,
                        excludedApps: [String], excludedDomains: [String]) -> Bool {
        DictationLearningPolicy.permits(
            appName: appName, bundleID: edit.bundleID,
            surface: DictationLearningSurface(windowTitle: "", pageURL: edit.pageURL),
            excludedApps: excludedApps, excludedDomains: excludedDomains)
    }

    @MainActor
    static func appName(forBundleID bundleID: String?) -> String {
        guard let bundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return bundleID ?? ""
        }
        let name = FileManager.default.displayName(atPath: url.path)
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }
}
