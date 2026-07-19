import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var viewModel: MirrorViewModel

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(viewModel.statusSentence)
                        .accessibilityAddTraits(.updatesFrequently)
                    Toggle("Connect to PC", isOn: connectBinding)
                        .accessibilityHint("Connects to the NVRS add-on on your PC over Tailscale.")
                    Toggle("Speak on this iPhone", isOn: speakBinding)
                        .accessibilityHint("Turn off to silence mirrored speech without disconnecting. Two-finger double tap anywhere toggles this too.")
                } header: {
                    Text("Status")
                }

                Section {
                    Text(viewModel.lastSpoken.isEmpty ? "Nothing yet." : viewModel.lastSpoken)
                        .accessibilityLabel(
                            viewModel.lastSpoken.isEmpty
                                ? "Last spoken: nothing yet"
                                : "Last spoken: \(viewModel.lastSpoken)"
                        )
                } header: {
                    Text("Last spoken")
                }

                Section {
                    Button("Speak test phrase") {
                        viewModel.speakTest()
                    }
                    .accessibilityHint("Speaks locally through the same audio path as mirrored speech, without the PC.")
                    Text("Bytes \(viewModel.bytesReceived), lines \(viewModel.linesParsed), bad \(viewModel.decodeFailures), received \(viewModel.envelopesReceived), spoken \(viewModel.utterancesStarted).")
                        .accessibilityAddTraits(.updatesFrequently)
                    if let audioError = viewModel.audioError {
                        Text("Audio session error: \(audioError)")
                    }
                } header: {
                    Text("Diagnostics")
                }

                Section {
                    NavigationLink("Settings") {
                        SettingsView()
                    }
                }
            }
            .navigationTitle("NVRS")
        }
        // Magic tap: the app's one most important toggle, reachable from anywhere.
        .accessibilityAction(.magicTap) {
            viewModel.toggleLocalMute()
        }
    }

    private var connectBinding: Binding<Bool> {
        Binding(
            get: { viewModel.isConnectEnabled },
            set: { enabled in
                if enabled {
                    viewModel.connect()
                } else {
                    viewModel.disconnect()
                }
            }
        )
    }

    private var speakBinding: Binding<Bool> {
        Binding(
            get: { !viewModel.isLocalSpeechMuted },
            set: { _ in viewModel.toggleLocalMute() }
        )
    }
}
