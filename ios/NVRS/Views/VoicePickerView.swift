import AVFoundation
import SwiftUI

struct VoicePickerView: View {
    /// Selected iOS voice identifier; nil = the `noneLabel` option.
    @Binding var selection: String?
    var title: String = String(localized: "Voice")
    var noneLabel: String = String(localized: "System default")

    /// Which language groups are open. Only the selected voice's language
    /// starts open, so the list is a short scan of languages, not of every
    /// installed voice.
    @State private var expandedLanguages: Set<String> = []

    private struct LanguageGroup: Identifiable {
        let code: String
        let name: String
        let voices: [AVSpeechSynthesisVoice]
        var id: String { code }
    }

    private var voicesByLanguage: [LanguageGroup] {
        Dictionary(grouping: AVSpeechSynthesisVoice.speechVoices()) { $0.language }
            .map { code, voices in
                LanguageGroup(
                    code: code,
                    name: languageName(code),
                    voices: voices.sorted {
                        $0.name.localizedStandardCompare($1.name) == .orderedAscending
                    }
                )
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        List {
            Section {
                selectionRow(title: noneLabel, identifier: nil)
            }
            Section {
                ForEach(voicesByLanguage) { group in
                    DisclosureGroup(isExpanded: expansion(for: group.code)) {
                        ForEach(group.voices, id: \.identifier) { voice in
                            selectionRow(title: voice.name, identifier: voice.identifier)
                        }
                    } label: {
                        // A bare Text keeps this one VoiceOver element, so the
                        // only thing added to the name is the expanded state.
                        Text(group.name)
                    }
                }
            } header: {
                Text("Languages")
            }
        }
        .navigationTitle(title)
        .onAppear(perform: expandSelectedLanguage)
    }

    private func selectionRow(title: String, identifier: String?) -> some View {
        Button {
            selection = identifier
        } label: {
            HStack {
                Text(title)
                    .foregroundStyle(.primary)
                Spacer()
                if selection == identifier {
                    Image(systemName: "checkmark")
                        .accessibilityHidden(true)
                }
            }
        }
        .accessibilityAddTraits(selection == identifier ? [.isSelected] : [])
    }

    private func expansion(for code: String) -> Binding<Bool> {
        Binding(
            get: { expandedLanguages.contains(code) },
            set: { isExpanded in
                if isExpanded {
                    expandedLanguages.insert(code)
                } else {
                    expandedLanguages.remove(code)
                }
            }
        )
    }

    private func expandSelectedLanguage() {
        guard let selection,
              let voice = AVSpeechSynthesisVoice(identifier: selection)
        else { return }
        expandedLanguages.insert(voice.language)
    }

    private func languageName(_ code: String) -> String {
        Locale.current.localizedString(forIdentifier: code) ?? code
    }
}
