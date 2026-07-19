import AVFoundation
import SwiftUI

/// Maps PC (NVDA) voices to iPhone voices. Rows appear automatically as
/// the PC reports voices; unmapped voices switch by language automatically.
struct PCVoiceMappingView: View {
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        Form {
            if settings.pcVoices.isEmpty {
                Section {
                    Text("No PC voices seen yet. Voices appear here automatically once the PC connects and speaks.")
                }
            } else {
                Section {
                    ForEach($settings.pcVoices) { $entry in
                        NavigationLink {
                            VoicePickerView(
                                selection: $entry.phoneVoiceId,
                                title: entry.label,
                                noneLabel: String(localized: "Automatic (by language)")
                            )
                        } label: {
                            LabeledContent(entry.label, value: phoneVoiceName(entry.phoneVoiceId))
                        }
                        .accessibilityAction(named: "Reset to automatic") {
                            entry.phoneVoiceId = nil
                        }
                        .contextMenu {
                            Button("Reset to automatic") {
                                entry.phoneVoiceId = nil
                            }
                        }
                    }
                } footer: {
                    Text("PC voices without a mapping switch the phone to a voice of the same language automatically, preferring the same persona or engine family as your current voice.")
                }
            }
        }
        .navigationTitle("PC voice mapping")
    }

    private func phoneVoiceName(_ identifier: String?) -> String {
        guard let identifier,
              let voice = AVSpeechSynthesisVoice(identifier: identifier)
        else { return String(localized: "Automatic") }
        return voice.name
    }
}
