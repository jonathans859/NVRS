import AVFoundation
import SwiftUI

struct VoicePickerView: View {
    /// Selected iOS voice identifier; nil = the `noneLabel` option.
    @Binding var selection: String?
    var title: String = String(localized: "Voice")
    var noneLabel: String = String(localized: "System default")

    private var voicesByLanguage: [(language: String, voices: [AVSpeechSynthesisVoice])] {
        let grouped = Dictionary(grouping: AVSpeechSynthesisVoice.speechVoices()) { $0.language }
        return grouped
            .map { (language: languageName($0.key), voices: $0.value.sorted { $0.name < $1.name }) }
            .sorted { $0.language < $1.language }
    }

    var body: some View {
        List {
            Section {
                selectionRow(title: noneLabel, identifier: nil)
            }
            ForEach(voicesByLanguage, id: \.language) { group in
                Section {
                    ForEach(group.voices, id: \.identifier) { voice in
                        selectionRow(title: voice.name, identifier: voice.identifier)
                    }
                } header: {
                    Text(group.language)
                }
            }
        }
        .navigationTitle(title)
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

    private func languageName(_ code: String) -> String {
        Locale.current.localizedString(forIdentifier: code) ?? code
    }
}
