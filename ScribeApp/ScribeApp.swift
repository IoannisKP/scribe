import SwiftUI

@main
struct ScribeApp: App {
    @StateObject private var recorder = MeetingRecorderViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView(recorder: recorder)
        }
        .windowStyle(.automatic)
        .defaultSize(width: 960, height: 820)
        .commands {
            CommandGroup(after: .newItem) {
                Button(ScribeCopy.Shell.importMedia) {
                    recorder.chooseMediaForImport()
                }
                .keyboardShortcut("o", modifiers: [.command])
                .disabled(!recorder.canImportMedia)
            }
            CommandGroup(after: .textEditing) {
                Button(ScribeCopy.Shell.search) {
                    NotificationCenter.default.post(
                        name: .scribeFocusSearch,
                        object: nil
                    )
                }
                .keyboardShortcut("k", modifiers: [.command])
            }
            CommandMenu("Diagnostics") {
                Button("Run System Tap Privacy Diagnostic…") {
                    recorder.runSystemTapPrivacyDiagnostic()
                }
                .disabled(!recorder.canRunSystemTapDiagnostic)

                Button("Append System Tap Timing Sample") {
                    recorder.runSystemTapTimingSample()
                }
                .disabled(!recorder.canRunSystemTapDiagnostic)

                Divider()

                Button("Reveal System Tap Diagnostic Log") {
                    recorder.revealSystemTapDiagnosticLog()
                }
            }
        }
    }
}
