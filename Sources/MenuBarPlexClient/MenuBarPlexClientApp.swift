import AppKit
import Combine
import SwiftUI

@main
struct KirinApp: App {
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
    private var appState: AppState?
    private var pendingOpenURLs: [URL] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        flushPendingOpenURLs()
    }

    func configure(appState: AppState) {
        self.appState = appState
        guard statusController == nil else { return }
        statusController = StatusItemController(appState: appState)
        flushPendingOpenURLs()
    }

    func application(_ sender: NSApplication, open urls: [URL]) {
        guard !urls.isEmpty else { return }
        pendingOpenURLs.append(contentsOf: urls)
        flushPendingOpenURLs()
    }

    private func flushPendingOpenURLs() {
        guard let appState,
              let statusController,
              !pendingOpenURLs.isEmpty else {
            return
        }

        let urls = pendingOpenURLs
        pendingOpenURLs = []
        Task {
            await appState.openLocalFilesFromFinder(urls)
            statusController.showPanel()
        }
    }
}

