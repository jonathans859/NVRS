import AVFoundation
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var viewModel: MirrorViewModel

    var body: some View {
        Form {
            Section {
                TextField("Tailscale IP or hostname", text: $settings.host)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .accessibilityLabel("PC address")
                    .accessibilityHint("The PC's Tailscale IP or MagicDNS name.")
                TextField("Port", value: $settings.port, format: .number.grouping(.never))
                    .keyboardType(.numberPad)
                    .accessibilityHint("Must match the port in NVDA's NVRS settings. Default 6877.")
                SecureField("Shared secret", text: $settings.secret)
                    .accessibilityHint("Must match the shared secret set in NVDA's NVRS settings panel.")
                Toggle("Connect automatically", isOn: $settings.autoConnect)
                Toggle("Stay awake in background", isOn: $settings.keepAliveInBackground)
                    .accessibilityHint("Keeps the connection alive while the phone is locked or the app is in the background, at some battery cost. Takes full effect on reconnect.")
            } header: {
                Text("Connection")
            }

            Section {
                NavigationLink {
                    VoicePickerView()
                } label: {
                    LabeledContent("Voice", value: settings.voiceDisplayName)
                }
                rateSlider
                pitchSlider
                volumeSlider
                Toggle("Shorten pauses", isOn: $settings.shortenPauses)
                    .accessibilityHint("Removes pause-causing punctuation from spoken text and shortens explicit breaks, approximating the PC driver's shorten all pauses. Costs some sentence intonation. Works with any voice.")
            } header: {
                Text("Speech")
            } footer: {
                Text("NVDA's pitch, rate and volume changes are applied relative to these baselines. Pause shortening requires an Eloquence voice and is experimental — test with the speak test button.")
            }

            Section {
                NavigationLink("Notification filters") {
                    FiltersView()
                }
            } footer: {
                Text("Get a notification when NVDA speaks matching text, even while other audio plays.")
            }
        }
        .navigationTitle("Settings")
    }

    private var rateSlider: some View {
        Slider(value: $settings.baseRate, in: 0.1...1.0) {
            Text("Speech rate")
        }
        .accessibilityValue("\(Int(settings.baseRate * 100)) percent")
    }

    private var pitchSlider: some View {
        Slider(value: $settings.basePitch, in: 0.5...2.0) {
            Text("Pitch")
        }
        .accessibilityValue("\(Int(settings.basePitch * 100)) percent")
    }

    private var volumeSlider: some View {
        Slider(value: $settings.baseVolume, in: 0.0...1.0) {
            Text("Volume")
        }
        .accessibilityValue("\(Int(settings.baseVolume * 100)) percent")
    }
}
