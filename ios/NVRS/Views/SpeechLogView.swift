import SwiftUI

/// What has been mirrored so far, newest first. Behind a button like the
/// diagnostics are: the main screen stays about the connection.
struct SpeechLogView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var viewModel: MirrorViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if viewModel.speechLog.isEmpty {
                        Text("Nothing yet.")
                    } else {
                        ForEach(viewModel.speechLog) { line in
                            Text(line.text)
                        }
                    }
                } footer: {
                    Text("Newest first, keeping the last \(settings.speechLogLimit) lines.")
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Speech log")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
