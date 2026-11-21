import SwiftUI

struct LearnedCorrectionsSection: View {
    @Binding var isOn: Bool
    @ObservedObject var store: DictationCorrectionsStore
    let focusedSettingID: String?

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
            }
            .onAppear { store.load() }
        }
    }
}
