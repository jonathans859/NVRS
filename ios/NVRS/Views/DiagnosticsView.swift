import SwiftUI

/// The counters, out of the way until asked for. Same lines the copy button
/// puts on the clipboard, so a bug report matches what was on screen.
struct DiagnosticsView: View {
    @EnvironmentObject private var viewModel: MirrorViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(viewModel.diagnosticLines.indices, id: \.self) { index in
                        Text(viewModel.diagnosticLines[index])
                            .accessibilityAddTraits(.updatesFrequently)
                    }
                }
                Section {
                    Button("Copy stats") {
                        Clipboard.copy(statsText)
                        Announce.post(String(localized: "Stats copied"))
                    }
                    .accessibilityHint("Copies every diagnostic line, plus the build number, so it can be pasted into a bug report.")
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Diagnostics")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    /// Self-contained on purpose: pasted somewhere else, it still says which
    /// build produced these numbers.
    private var statsText: String {
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
        return (["NVRS stats, build \(build)"] + viewModel.diagnosticLines).joined(separator: "\n")
    }
}
