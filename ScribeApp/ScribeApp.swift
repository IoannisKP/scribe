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
                Button("Import audio or video…") {
                    recorder.chooseMediaForImport()
                }
                .keyboardShortcut("o", modifiers: [.command])
                .disabled(!recorder.canImportMedia)
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
