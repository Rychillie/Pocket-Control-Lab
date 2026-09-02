import SwiftUI

@main
struct PocketControlLabApp: App {
    @State private var lab = PocketLabModel()

    var body: some Scene {
        WindowGroup("Pocket Control Lab") {
            ContentView(lab: lab)
        }
        .defaultSize(width: 1_300, height: 920)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Refresh Safe Investigation") {
                    lab.refreshInspection()
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }
    }
}
