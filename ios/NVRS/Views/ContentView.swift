import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var viewModel: MirrorViewModel

    var body: some View {
        #if os(iOS)
        // Magic tap: the app's one most important toggle, reachable from anywhere.
        navigationForm
            .accessibilityAction(.magicTap) {
                viewModel.toggleLocalMute()
            }
        #else
        navigationForm
            .frame(minWidth: 440, minHeight: 480)
        #endif
    }

    private var navigationForm: some View {
        NavigationStack {
            Form {
                Section {
                    Text(viewModel.statusSentence)
                        .accessibilityAddTraits(.updatesFrequently)
                    if viewModel.isSpeechPaused {
                        Text("Speech paused on the PC.")
                            .accessibilityAddTraits(.updatesFrequently)
                    }
                    Button(viewModel.isConnectEnabled ? "Disconnect" : "Connect") {
                        if viewModel.isConnectEnabled {
                            viewModel.disconnect()
                        } else {
                            viewModel.connect()
                        }
                    }
                    .accessibilityHint(
                        viewModel.isConnectEnabled
                            ? "Drops the link to the NVRS add-on on your PC."
                            : "Connects to the NVRS add-on on your PC over Tailscale."
                    )
                    #if os(iOS)
                    Toggle("Speak on this iPhone", isOn: speakBinding)
                        .accessibilityHint("Turn off to silence mirrored speech without disconnecting. Two-finger double tap anywhere toggles this too.")
                    #else
                    Toggle("Speak on this Mac", isOn: speakBinding)
                        .accessibilityHint("Turn off to silence mirrored speech without disconnecting.")
                    #endif
                    if viewModel.pcMuteAllowed {
                        Toggle("Mute NVDA Speech Audio on PC", isOn: pcMuteBinding)
                            .accessibilityHint("Silences NVDA's own audio on the PC while you listen here. The PC unmutes itself when you disconnect.")
                    }
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
                    ForEach(viewModel.diagnosticLines.indices, id: \.self) { index in
                        Text(viewModel.diagnosticLines[index])
                            .accessibilityAddTraits(.updatesFrequently)
                    }
                    Button("Copy stats") {
                        Clipboard.copy(statsText)
                        Announce.post(String(localized: "Stats copied"))
                    }
                    .accessibilityHint("Copies every diagnostic line, plus the build number, so it can be pasted into a bug report.")
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
        // Grouped is already the iOS default; on macOS it turns the bare
        // form into the familiar settings-style layout.
        .formStyle(.grouped)
    }

    /// Self-contained on purpose: pasted somewhere else, it still says which
    /// build produced these numbers.
    private var statsText: String {
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
        return (["NVRS stats, build \(build)"] + viewModel.diagnosticLines).joined(separator: "\n")
    }

    private var pcMuteBinding: Binding<Bool> {
        Binding(
            get: { viewModel.isPCAudioMuted },
            set: { viewModel.setPCAudioMuted($0) }
        )
    }

    private var speakBinding: Binding<Bool> {
        Binding(
            get: { !viewModel.isLocalSpeechMuted },
            set: { _ in viewModel.toggleLocalMute() }
        )
    }
}
