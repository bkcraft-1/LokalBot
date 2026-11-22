import AppKit
import SwiftUI

struct LearnedCorrectionsSection: View {
    @Binding var isOn: Bool
    @ObservedObject var store: DictationCorrectionsStore
    let settings: AppSettings
    let focusedSettingID: String?
    @State private var wisprPlan: WisprCorrectionsImport.Plan?
    @State private var wisprStatus: LocalizedStringKey?

    var body: some View {
        Section {
            SettingsSwitchRow("Learn from my corrections",
                              info: "When you fix a misheard word right after dictating, in the same field, LokalBot remembers "
                                  + "the fix. Only the word pairs are kept, encrypted on this Mac. A word you fixed helps the "
                                  + "next transcription; a fix you make twice is applied automatically. Excluded apps and "
                                  + "websites, private windows, and password fields are skipped. Turning this off deletes them.",
                              isOn: $isOn)
                .settingTarget("settings.dictationLearnFromCorrections", selected: focusedSettingID)
                .accessibilityIdentifier("settings.dictationLearnFromCorrections")
        }
        if isOn {
            Section {
                if store.corrections.isEmpty {
                    SettingsHelp("No corrections learned yet.")
                        .accessibilityIdentifier("dictation.corrections.empty")
                } else {
                    ForEach(store.corrections.sorted { $0.lastSeen > $1.lastSeen }) { correction in
                        HStack(spacing: 8) {
                            Text(verbatim: "\(correction.heard) → \(correction.corrected)")
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(verbatim: "×\(correction.count)").settingsSecondary()
                            Button { store.delete(correction.id) } label: { Image(systemName: "trash") }
                                .buttonStyle(.borderless)
                                .accessibilityLabel(Text("Delete"))
                        }
                    }
                    Button("Forget all corrections", role: .destructive) { store.forgetAll() }
                        .accessibilityIdentifier("dictation.corrections.forget")
                }
                if WisprFlowLibrary.defaultFolder != nil {
                    wisprImport
                }
            }
            .onAppear { store.load() }
        }
    }

    private var wisprImport: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button("Import from Wispr Flow…") { chooseWisprHistory() }
                .accessibilityIdentifier("dictation.corrections.importWispr")
                .confirmationDialog(
                    Text("Add \(wisprPlan?.distinctPairs ?? 0) corrections from Wispr Flow?"),
                    isPresented: Binding(get: { wisprPlan != nil }, set: { if !$0 { wisprPlan = nil } })
                ) {
                    Button("Add Corrections") {
                        if let plan = wisprPlan {
                            let added = store.recordEarlier(plan.fixes.map { (pair: $0.pair, date: $0.date) })
                            lokalbotLog("wispr corrections import added=\(added) of fixes=\(plan.fixes.count)")
                        }
                        wisprPlan = nil
                    }
                } message: {
                    Text("Fixes you made more than once in Wispr Flow are applied automatically from now on. Only the word pairs are kept; fixes older than 180 days and dictations in excluded apps or websites are left out.")
                }
            if let wisprStatus {
                Text(wisprStatus).settingsSecondary()
            }
        }
    }

    private func chooseWisprHistory() {
        let panel = NSOpenPanel()
        panel.message = settings.appLanguage.localized(
            "Choose Wispr Flow's flow.sqlite. LokalBot reads only the dictations you edited there.")
        panel.prompt = settings.appLanguage.localized("Import")
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = WisprFlowLibrary.defaultFolder
        guard panel.runModal() == .OK, let picked = panel.url else { return }
        wisprStatus = nil
        let excludedApps = settings.excludedAppList
        let excludedDomains = settings.excludedScreenDomainList
        Task {
            let edits = await Task.detached(priority: .userInitiated) {
                Result { try WisprFlowLibrary.dictationEdits(at: picked) }
            }.value
            switch edits {
            case .success(let edits):
                var appNames: [String: String] = [:]
                let plan = WisprCorrectionsImport.plan(
                    edits, now: Date(),
                    permits: { edit in
                        let key = edit.bundleID ?? ""
                        let name = appNames[key] ?? WisprCorrectionsImport.appName(forBundleID: edit.bundleID)
                        appNames[key] = name
                        return WisprCorrectionsImport.permits(
                            edit, appName: name, excludedApps: excludedApps, excludedDomains: excludedDomains)
                    },
                    isEverydayWord: { DictationCorrection.isEverydayEnglishWord($0) })
                lokalbotLog("wispr corrections import planned edited=\(plan.editedDictations) "
                    + "withFixes=\(plan.dictationsWithFixes) fixes=\(plan.fixes.count) pairs=\(plan.distinctPairs) "
                    + "automatic=\(plan.automaticPairs) excluded=\(plan.excluded) olderOrUndated=\(plan.olderOrUndated)")
                if plan.fixes.isEmpty {
                    wisprStatus = "Wispr Flow's history has no corrections to add."
                } else {
                    wisprPlan = plan
                }
            case .failure:
                lokalbotLog("wispr corrections import couldn't read the database")
                wisprStatus = "Couldn't read Wispr Flow's history."
            }
        }
    }
}
