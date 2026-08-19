import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var viewModel: MirrorViewModel
    @State private var isShowingDiagnostics = false

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
                    if viewModel.speechLog.isEmpty {
                        Text("Nothing yet.")
                    } else {
                        ForEach(viewModel.speechLog) { line in
                            Text(line.text)
                        }
                    }
                } header: {
                    Text("Speech log")
                } footer: {
                    Text("Newest first, keeping the last \(settings.speechLogLimit) lines.")
                }

                Section {
                    Button("Diagnostics") {
                        isShowingDiagnostics = true
                    }
                    .accessibilityHint("Opens the counters for bytes, lines and speech, and the button that copies them.")
                    NavigationLink("Settings") {
                        SettingsView()
                    }
                }
            }
            .navigationTitle("NVRS")
            .sheet(isPresented: $isShowingDiagnostics) {
                DiagnosticsView()
            }
        }
        // Grouped is already the iOS default; on macOS it turns the bare
        // form into the familiar settings-style layout.
        .formStyle(.grouped)
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
