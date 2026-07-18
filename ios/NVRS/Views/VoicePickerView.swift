import AVFoundation
import SwiftUI

struct VoicePickerView: View {
    @EnvironmentObject private var settings: SettingsStore

    private var voicesByLanguage: [(language: String, voices: [AVSpeechSynthesisVoice])] {
        let grouped = Dictionary(grouping: AVSpeechSynthesisVoice.speechVoices()) { $0.language }
        return grouped
            .map { (language: languageName($0.key), voices: $0.value.sorted { $0.name < $1.name }) }
            .sorted { $0.language < $1.language }
    }

    var body: some View {
        List {
            Section {
                selectionRow(title: String(localized: "System default"), identifier: nil)
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
        .navigationTitle("Voice")
    }

    private func selectionRow(title: String, identifier: String?) -> some View {
        Button {
            settings.voiceIdentifier = identifier
        } label: {
            HStack {
                Text(title)
                    .foregroundStyle(.primary)
                Spacer()
                if settings.voiceIdentifier == identifier {
                    Image(systemName: "checkmark")
                        .accessibilityHidden(true)
                }
            }
        }
        .accessibilityAddTraits(settings.voiceIdentifier == identifier ? [.isSelected] : [])
    }

    private func languageName(_ code: String) -> String {
        Locale.current.localizedString(forIdentifier: code) ?? code
    }
}
