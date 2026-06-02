import AppKit
import Combine
import SwiftUI

@main
struct PlexTrayApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let appState: AppState

    init() {
        let appState = AppState()
        self.appState = appState
        appDelegate.configure(appState: appState)
    }

    var body: some Scene {
        Settings {
            EmptyView()
        }
        .commands {
            CommandGroup(replacing: .appSettings) { }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusController: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    func configure(appState: AppState) {
        guard statusController == nil else { return }
        statusController = StatusItemController(appState: appState)
    }
}


