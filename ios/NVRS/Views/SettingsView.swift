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
                Button("Add to saved connections") {
                    guard let connection = settings.saveCurrentConnection() else { return }
                    Announce.post(String(localized: "Saved \(connection.id)"))
                }
                .disabled(settings.connectionToSave == nil)
                .accessibilityHint("Saves the address, port and shared secret to the list below.")
                ForEach(settings.savedConnections) { connection in
                    savedConnectionRow(connection)
                }
                .onDelete { settings.deleteSavedConnections(atOffsets: $0) }
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
                    .accessibilityHint("Scales the rate slider by NVDA's own speech rate, so changing the rate on the PC changes it here too. The slider still sets the baseline.")
                NavigationLink("PC voice mapping") {
                    PCVoiceMappingView()
                }
                rateSlider
                rateField
                pitchSlider
                volumeSlider
                Button("Reset rate, pitch and volume") {
                    settings.resetSpeechBaselines()
                    Announce.post(String(localized: "Rate, pitch and volume reset"))
                }
                .accessibilityHint("Puts the three sliders above back to their default values.")
                Button("Speak test phrase") {
                    viewModel.speakTest()
                }
                .accessibilityHint("Speaks locally through the same audio path as mirrored speech, without the PC.")
            } header: {
                Text("Speech")
            } footer: {
                Text("NVDA's pitch, rate and volume changes are applied relative to these baselines.")
            }

            Section {
                Picker("Shorten pauses", selection: $settings.pauseMode) {
                    ForEach(PauseMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .accessibilityHint("Shortens the silence in speech the way the IBMTTS driver does on the PC. Speech is rendered and played by NVRS instead of by the system.")
                if settings.pauseMode != .off {
                    pauseFactorSlider
                    pauseLimitSlider
                }
                NavigationLink("Pause probe") {
                    RenderProbeView()
                }
                .accessibilityHint("Measures the pauses in this voice and compares shortened against unshortened playback.")
            } header: {
                Text("Pauses")
            } footer: {
                Text("Shortening only changes the length of the silence — words, intonation and punctuation are untouched. If a voice cannot be rendered this way, or the text is longer than the limit, speech falls back to the system path automatically.")
            }

            Section {
                logLimitSlider
            } header: {
                Text("Speech log")
            } footer: {
                Text("How many spoken lines the main screen keeps. The oldest fall off the end.")
            }
        }
        .navigationTitle("Settings")
    }

    /// One saved address. Activating it fills the host and port fields; the
    /// one matching them carries the selected trait. Delete comes from
    /// `.onDelete` on iOS (swipe, and VoiceOver's own Delete action); macOS
    /// has no swipe in a Form, so it gets a named action and a context menu.
    private func savedConnectionRow(_ connection: SavedConnection) -> some View {
        let isCurrent = settings.isCurrent(connection)
        return Button {
            settings.select(connection)
        } label: {
            HStack {
                Text(connection.id)
                    .foregroundStyle(.primary)
                Spacer()
                if isCurrent {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
        }
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
        .accessibilityHint("Uses this address, port and shared secret for the connection.")
        #if os(macOS)
        .accessibilityAction(named: "Delete") { delete(connection) }
        .contextMenu {
            Button("Delete", role: .destructive) { delete(connection) }
        }
        #endif
    }

    private func delete(_ connection: SavedConnection) {
        settings.deleteSavedConnection(connection)
    }

    /// In steps of five percent, so the arrow keys and VoiceOver's
    /// adjustments land on round numbers. The adjustable action is explicit
    /// because the slider's own may not honour the step.
    private var rateSlider: some View {
        Slider(value: $settings.baseRate, in: 0.1...1.0, step: 0.05) {
            Text("Speech rate")
        }
        .accessibilityValue("\(ratePercent) percent")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment:
                stepRate(up: true)
            case .decrement:
                stepRate(up: false)
            @unknown default:
                break
            }
        }
    }

    /// The same rate, typed instead of stepped.
    private var rateField: some View {
        TextField("Rate in percent", value: ratePercentBinding, format: .number.grouping(.never))
            .numberFieldTraits()
            .accessibilityHint("Speech rate from 10 to 100 percent. The default is 50.")
    }

    private var ratePercent: Int {
        Int((settings.baseRate * 100).rounded())
    }

    private var ratePercentBinding: Binding<Int> {
        Binding(
            get: { ratePercent },
            set: { setRatePercent($0) }
        )
    }

    private func setRatePercent(_ percent: Int) {
        settings.baseRate = Double(min(max(percent, 10), 100)) / 100
    }

    /// Snaps to the five-percent grid on the way, so a value typed or left
    /// over from the old free slider (say 53) goes to 55 or 50, not 58 or 48.
    private func stepRate(up: Bool) {
        let current = ratePercent
        setRatePercent(up ? (current / 5 + 1) * 5 : ((current + 4) / 5 - 1) * 5)
    }

    private var pitchSlider: some View {
        Slider(value: $settings.basePitch, in: 0.5...2.0) {
            Text("Pitch")
        }
        .accessibilityValue("\(Int(settings.basePitch * 100)) percent")
    }

    /// How much of each pause survives. Tunable in the field on purpose:
    /// the right value is a matter of taste, and a TestFlight round trip
    /// costs ten minutes.
    private var pauseFactorSlider: some View {
        Slider(value: $settings.pauseFactor, in: 0.1...1.0, step: 0.05) {
            Text("Pause length")
        }
        .accessibilityValue("\(Int(settings.pauseFactor * 100)) percent of the original")
    }

    /// How long a text may be and still be shortened. Rendering is batch —
    /// nothing plays until the whole utterance has been rendered — so there
    /// is a length beyond which the delay costs more than the shortening is
    /// worth. Where that lies depends on the device and the voice, so it is
    /// here rather than baked in.
    private var pauseLimitSlider: some View {
        Slider(value: pauseLimitBinding, in: 200...6000, step: 200) {
            Text("Longest text to shorten")
        }
        .accessibilityValue("\(settings.pauseCharacterLimit) characters")
    }

    private var pauseLimitBinding: Binding<Double> {
        Binding(
            get: { Double(settings.pauseCharacterLimit) },
            set: { settings.pauseCharacterLimit = Int($0) }
        )
    }

    private var logLimitSlider: some View {
        Slider(value: logLimitBinding, in: 10...500, step: 10) {
            Text("Lines to keep")
        }
        .accessibilityValue("\(settings.speechLogLimit) lines")
    }

    private var logLimitBinding: Binding<Double> {
        Binding(
            get: { Double(settings.speechLogLimit) },
            set: { settings.speechLogLimit = Int($0) }
        )
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
