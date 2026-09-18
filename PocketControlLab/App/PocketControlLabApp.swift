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

private struct MenuBarExtraLabel: View {
    @Bindable var session: DeviceSession

    var body: some View {
        let presentation = session.connectionPresentation

        HStack(spacing: 3) {
            Image(systemName: presentation.systemImage)
                .symbolRenderingMode(.hierarchical)

            MenuBarSeverityDot(severity: presentation.severity)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(presentation.accessibilityLabel)
        .accessibilityHint("Opens Pocket Control Lab connection status and safe actions.")
        .help(presentation.accessibilityLabel)
    }
}

private struct MenuBarContent: View {
    @Bindable var session: DeviceSession
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let presentation = session.connectionPresentation

        Text("Pocket Control Lab")
            .font(.headline)
        Text(presentation.title)
            .font(.subheadline.weight(.semibold))
        Text(presentation.detail)
            .foregroundStyle(.secondary)

        Divider()

        switch presentation.nextAction {
        case .refreshDetection:
            Button("Refresh Detection", systemImage: "arrow.clockwise") {
                session.refreshPassiveDetection()
            }
            .accessibilityHint("Performs one additional passive USB detection scan.")

            Divider()

            diagnosticsButton
        case .openDiagnostics, nil:
            diagnosticsButton
        }

        Divider()

        Button("Quit", systemImage: "power") {
            NSApplication.shared.terminate(nil)
        }
    }

    private var diagnosticsButton: some View {
        Button("Open Diagnostics", systemImage: "wrench.and.screwdriver") {
            openWindow(id: "diagnostics")
        }
        .accessibilityHint("Opens the engineering diagnostics window.")
    }
}

private struct MenuBarSeverityDot: View {
    let severity: ConnectionSeverity

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 6, height: 6)
            .accessibilityHidden(true)
    }

    private var color: Color {
        switch severity {
        case .neutral:
            .secondary
        case .attention:
            .blue
        case .warning:
            .orange
        case .ready:
            .green
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
