import SwiftUI

/// Diagnostics for pause shortening: what the pauses in this voice actually
/// measure, and how shortened playback compares against unshortened, back to
/// back. Notes in `.claude-notes/pause-shortening-ios-v4.md`.
struct RenderProbeView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var viewModel: MirrorViewModel

    /// "Play shortened" must demonstrate something even while the live
    /// setting is still off.
    private var shorteningMode: PauseMode {
        settings.pauseMode == .off ? .all : settings.pauseMode
    }

    var body: some View {
        Form {
            Section {
                Button("Measure only") {
                    viewModel.runRenderProbe(mode: settings.pauseMode, silent: true)
                }
                .disabled(viewModel.isProbing)
                .accessibilityHint("Renders the phrase without playing it and reports the pauses it found.")

                Button("Play unshortened") {
                    viewModel.runRenderProbe(mode: .off, silent: false)
                }
                .disabled(viewModel.isProbing)
                .accessibilityHint("Plays the rendered phrase with every pause intact. The reference for comparison.")

                Button("Play shortened") {
                    viewModel.runRenderProbe(mode: shorteningMode, silent: false)
                }
                .disabled(viewModel.isProbing)
                .accessibilityHint("Plays the same render with pauses shortened, so the two can be compared back to back.")
            } header: {
                Text("Offline render")
            } footer: {
                Text("The phrase is \(OfflineRenderProbe.phrase) Compare the two playbacks back to back; the setting above decides how mirrored speech behaves.")
            }

            Section {
                if viewModel.probeReport.isEmpty {
                    Text("Not run yet.")
                } else {
                    ForEach(viewModel.probeReport.indices, id: \.self) { index in
                        Text(viewModel.probeReport[index])
                    }
                    Button("Copy result") {
                        Clipboard.copy(reportText)
                        Announce.post(String(localized: "Probe result copied"))
                    }
                    .accessibilityHint("Copies the whole report, plus the phrase and build number, so it can be pasted elsewhere.")
                }
            } header: {
                Text("Result")
            }
        }
        .navigationTitle("Pause probe")
    }

    /// Self-contained on purpose: pasted somewhere else, it still says which
    /// build and which phrase produced these numbers.
    private var reportText: String {
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
        let header = [
            "NVRS pause probe, build \(build)",
            "Phrase: \(OfflineRenderProbe.phrase)",
        ]
        return (header + viewModel.probeReport).joined(separator: "\n")
    }
}
