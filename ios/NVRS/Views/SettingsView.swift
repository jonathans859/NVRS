import AVFoundation
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var viewModel: MirrorViewModel

    var body: some View {
        Form {
            Section {
                TextField("Tailscale IP or hostname", text: $settings.host)
                    .hostFieldTraits()
                    .autocorrectionDisabled()
                    .accessibilityLabel("PC address")
                    .accessibilityHint("The PC's Tailscale IP or MagicDNS name.")
                TextField("Port", value: $settings.port, format: .number.grouping(.never))
                    .numberFieldTraits()
                    .accessibilityHint("Must match the port in NVDA's NVRS settings. Default 6877.")
                SecureField("Shared secret", text: $settings.secret)
                    .accessibilityHint("Must match the shared secret set in NVDA's NVRS settings panel.")
                Toggle("Connect automatically", isOn: $settings.autoConnect)
                #if os(iOS)
                Toggle("Stay awake in background", isOn: $settings.keepAliveInBackground)
                    .accessibilityHint("Keeps the connection alive while the phone is locked or the app is in the background, at some battery cost. Takes full effect on reconnect.")
                #endif
            } header: {
                Text("Connection")
            }

            Section {
                NavigationLink {
                    VoicePickerView(selection: $settings.voiceIdentifier)
                } label: {
                    LabeledContent("Voice", value: settings.voiceDisplayName)
                }
                Toggle("Follow PC voice", isOn: $settings.followPCVoice)
                    .accessibilityHint("Switches the phone voice when NVDA's synth or voice changes, using the mapping below or the same language automatically.")
                Toggle("Follow PC rate", isOn: $settings.followPCRate)
                    .accessibilityHint("Tracks NVDA's speech rate instead of the local rate slider.")
                NavigationLink("PC voice mapping") {
                    PCVoiceMappingView()
                }
                rateSlider
                pitchSlider
                volumeSlider
            } header: {
                Text("Speech")
            } footer: {
                Text("NVDA's pitch, rate and volume changes are applied relative to these baselines.")
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

/// Soft-keyboard traits exist only on iOS; macOS text fields take the
/// string as typed.
private extension View {
    func hostFieldTraits() -> some View {
        #if os(iOS)
        return self.keyboardType(.URL).textInputAutocapitalization(.never)
        #else
        return self
        #endif
    }

    func numberFieldTraits() -> some View {
        #if os(iOS)
        return self.keyboardType(.numberPad)
        #else
        return self
        #endif
    }
}
