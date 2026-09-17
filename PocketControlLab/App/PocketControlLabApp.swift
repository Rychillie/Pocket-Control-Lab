import AppKit
import SwiftUI

@main
struct PocketControlLabApp: App {
    @NSApplicationDelegateAdaptor(AppLifecycleOwner.self) private var appLifecycle

    var body: some Scene {
        Window("Diagnostics", id: "diagnostics") {
            ContentView(session: appLifecycle.session)
                // The session is process-scoped. Future scenes can retrieve
                // this same instance instead of constructing their own model.
                .environment(appLifecycle.session)
        }
        .defaultSize(width: 1_300, height: 920)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)

        MenuBarExtra {
            MenuBarContent(session: appLifecycle.session)
        } label: {
            MenuBarExtraLabel(session: appLifecycle.session)
        }
        .menuBarExtraStyle(.menu)
    }
}

/// A deliberately small, privacy-safe status projection for the menu bar.
/// It has no access to device identifiers, preview state, logs, or UVC data.
struct MenuBarPresentation: Equatable {
    let connectionText: String
    let statusText = "Passive detection only"
    let systemImage: String

    init(identification: PocketIdentification?) {
        if identification != nil {
            connectionText = "Pocket detected"
            systemImage = "camera.fill"
        } else {
            connectionText = "No Pocket connected"
            systemImage = "camera"
        }
    }

    var accessibilityLabel: String {
        "Pocket Control Lab: \(connectionText). \(statusText). Diagnostics actions are explicit."
    }
}

private struct MenuBarExtraLabel: View {
    let session: DeviceSession

    var body: some View {
        let presentation = MenuBarPresentation(identification: session.device?.identification)

        Image(systemName: presentation.systemImage)
            .accessibilityLabel(presentation.accessibilityLabel)
            .help(presentation.accessibilityLabel)
    }
}

private struct MenuBarContent: View {
    @Bindable var session: DeviceSession
    @Environment(\.openWindow) private var openWindow

    private var presentation: MenuBarPresentation {
        MenuBarPresentation(identification: session.device?.identification)
    }

    var body: some View {
        Text("Pocket Control Lab")
            .font(.headline)
        Text(presentation.connectionText)
        Text(presentation.statusText)
            .foregroundStyle(.secondary)

        Divider()

        Button("Open Diagnostics", systemImage: "wrench.and.screwdriver") {
            openWindow(id: "diagnostics")
        }
        .accessibilityHint("Opens the engineering diagnostics window.")

        Button("Set Up Camera — Coming Soon", systemImage: "camera.badge.ellipsis") {}
            .disabled(true)
            .accessibilityLabel("Set Up Camera, unavailable")
            .accessibilityHint("Camera setup is not available in this version.")

        Divider()

        Button("Quit", systemImage: "power") {
            NSApplication.shared.terminate(nil)
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

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    @objc private func workspaceWillSleep(_ notification: Notification) {
        session.stopPassiveDiscovery()
    }

    @objc private func workspaceDidWake(_ notification: Notification) {
        session.startPassiveDiscovery()
    }

}
