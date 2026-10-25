#if os(macOS)
import AppKit
import SwiftUI

/// The menu-bar menu: the main screen's everyday controls, plus the way
/// into the full window. Each item has a bare-letter key that works while
/// the menu is open.
struct MenuBarMenu: View {
    @EnvironmentObject private var viewModel: MirrorViewModel

    var body: some View {
        Text(viewModel.statusSentence)
        if viewModel.isSpeechPaused {
            Text("Speech paused on the PC.")
        }
        Divider()
        Button(viewModel.isConnectEnabled ? "Disconnect" : "Connect") {
            if viewModel.isConnectEnabled {
                viewModel.disconnect()
            } else {
                viewModel.connect()
            }
        }
        .keyboardShortcut("c", modifiers: [])
        Toggle("Speak on this Mac", isOn: speakBinding)
            .keyboardShortcut("s", modifiers: [])
        if viewModel.pcMuteAllowed {
            Toggle("Mute NVDA Speech Audio on PC", isOn: pcMuteBinding)
                .keyboardShortcut("m", modifiers: [])
        }
        Divider()
        Button("Open NVRS…") {
            MainWindowController.shared.show()
        }
        .keyboardShortcut("o", modifiers: [])
        Divider()
        Button("Quit NVRS") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
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
#endif
