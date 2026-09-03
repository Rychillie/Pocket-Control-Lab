import AppKit
import SwiftUI

@main
struct PocketControlLabApp: App {
    @NSApplicationDelegateAdaptor(AppLifecycleOwner.self) private var appLifecycle

    var body: some Scene {
        WindowGroup("Pocket Control Lab") {
            ContentView(session: appLifecycle.session)
                // The session is process-scoped. Future scenes can retrieve
                // this same instance instead of constructing their own model.
                .environment(appLifecycle.session)
        }
        .defaultSize(width: 1_300, height: 920)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Refresh Read-Only Inspection") {
                    appLifecycle.session.refreshReadOnlyInspection()
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }
    }
}

/// Owns the one process-wide device session independently of SwiftUI view
/// lifetime. Its lifecycle callbacks intentionally restart passive USB
/// discovery only; preview, inspection, and write mode are never resumed.
@MainActor
private final class AppLifecycleOwner: NSObject, NSApplicationDelegate {
    let session = DeviceSession()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let workspaceNotifications = NSWorkspace.shared.notificationCenter
        workspaceNotifications.addObserver(
            self,
            selector: #selector(workspaceWillSleep(_:)),
            name: NSWorkspace.willSleepNotification,
            object: nil
        )
        workspaceNotifications.addObserver(
            self,
            selector: #selector(workspaceDidWake(_:)),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )

        session.startPassiveDiscovery()
    }

    func applicationWillTerminate(_ notification: Notification) {
        session.stopPassiveDiscovery()
    }

    @objc private func workspaceWillSleep(_ notification: Notification) {
        session.stopPassiveDiscovery()
    }

    @objc private func workspaceDidWake(_ notification: Notification) {
        session.startPassiveDiscovery()
    }

}
