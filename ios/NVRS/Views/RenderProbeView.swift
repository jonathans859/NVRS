import SwiftUI

/// Pause-shortening spike (see `.claude-notes/pause-shortening-ios-v4.md`).
/// Temporary diagnostics screen: it answers whether the selected voice can be
/// rendered to audio buffers and how much of its output is silence. Delete
/// this view together with `OfflineRenderProbe` if the answer is no.
struct RenderProbeView: View {
    @EnvironmentObject private var viewModel: MirrorViewModel

    var body: some View {
        Form {
            Section {
                Button("Render test phrase") {
                    viewModel.runRenderProbe(play: false)
                }
                .disabled(viewModel.isProbing)
                .accessibilityHint("Renders the phrase to audio buffers without playing it, then reports what came back.")

                Button("Render and play") {
                    viewModel.runRenderProbe(play: true)
                }
                .disabled(viewModel.isProbing)
                .accessibilityHint("Renders the phrase, then plays the buffers unmodified through the app's own audio engine. Should sound exactly like the test phrase.")
            } header: {
                Text("Offline render")
            } footer: {
                Text("Groundwork for shortening pauses: the phrase is \(OfflineRenderProbe.phrase)")
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
