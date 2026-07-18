import SwiftUI

struct FiltersView: View {
    @EnvironmentObject private var settings: SettingsStore
    @State private var newPattern = ""
    @State private var newIsRegex = false

    var body: some View {
        Form {
            Section {
                TextField("Text to match", text: $newPattern)
                    .autocorrectionDisabled()
                Toggle("Regular expression", isOn: $newIsRegex)
                Button("Add filter") {
                    addFilter()
                }
                .disabled(newPattern.trimmingCharacters(in: .whitespaces).isEmpty)
            } header: {
                Text("New filter")
            } footer: {
                Text("When NVDA speaks matching text, NVRS posts a notification. Matching is case-insensitive.")
            }

            if !settings.filters.isEmpty {
                Section {
                    ForEach($settings.filters) { $filter in
                        Toggle($filter.pattern.wrappedValue, isOn: $filter.isEnabled)
                            .accessibilityValue($filter.isRegex.wrappedValue ? "Regular expression" : "Plain text")
                            .accessibilityAction(named: "Delete filter") {
                                delete(filter)
                            }
                            .contextMenu {
                                Button(role: .destructive) {
                                    delete(filter)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                    }
                } header: {
                    Text("Filters")
                }
            }
        }
        .navigationTitle("Notification filters")
    }

    private func addFilter() {
        let pattern = newPattern.trimmingCharacters(in: .whitespaces)
        guard !pattern.isEmpty else { return }
        settings.filters.append(NotificationFilter(pattern: pattern, isRegex: newIsRegex))
        newPattern = ""
        newIsRegex = false
        NotificationFilterEngine.requestAuthorization()
    }

    private func delete(_ filter: NotificationFilter) {
        settings.filters.removeAll { $0.id == filter.id }
    }
}
