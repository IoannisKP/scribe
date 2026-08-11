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
        }
    }
}
