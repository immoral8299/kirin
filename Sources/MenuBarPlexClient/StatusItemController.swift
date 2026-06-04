import AppKit
import Combine
import QuartzCore
import SwiftUI

fileprivate enum StatusBarConfig {
    static let fallbackIconName = PlaybackStateIcon.statusSystemImageName(for: .buffering)
    static let fallbackText = "Initializing..."
    static let topRightScreenMargin = NSSize(width: 4, height: 4)
    static let panelSize = NSSize(width: 460, height: 520)
    static let iconFontSize: CGFloat = 11
    static let iconVerticalOffset: CGFloat = 1
    static let marqueeFontSize: CGFloat = 13
    static let iconTitleSpacing = "  "
    static let panelAnimationDuration: TimeInterval = 0.16
    static let panelAnimationOffset: CGFloat = 10
}

@MainActor
final class StatusItemController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let appState: AppState
    private let panelContainerView: NSView
    private let panelContentView = NSView(frame: .zero)
    private var rootView: NSHostingView<MenuBarRootView>!
    private let panel: MenuBarPanel
    private var cancellables = Set<AnyCancellable>()
    private var globalMouseMonitor: Any?
    private var isPanelPinned = false
    private var isPanelHiding = false
    private var hasRenderedResolvedStatus = false
    private var currentStatusIconName = ""
    private var currentStatusText = ""
    private var currentThemePreference: AppThemePreference?

    private let panelState = PanelState()

    init(appState: AppState) {
        self.appState = appState
        panelContainerView = Self.makePanelContainerView()
        panel = MenuBarPanel(
            contentRect: NSRect(origin: .zero, size: StatusBarConfig.panelSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        super.init()
        rootView = makeRootView()
        configurePanel()
        configureButton()
        configureContextMenu()
        configureOutsideClickMonitoring()
        applyThemePreference(appState.themePreference)
        applyFallbackStatus()
        bind(appState: appState)
        updateStatus(iconName: appState.statusIconName, text: appState.statusLine)
    }

    private func makeRootView() -> NSHostingView<MenuBarRootView> {
        NSHostingView(
            rootView: MenuBarRootView(
                appState: appState,
                panelState: panelState,
                onClose: { [weak self] in
                    self?.hidePanel()
                },
                onPinChange: { [weak self] isPinned in
                    self?.isPanelPinned = isPinned
                },
                onPanelPositionChange: { [weak self] in
                    self?.positionPanelIfVisible()
                }
            )
        )
    }

    private func configurePanel() {
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.becomesKeyOnlyIfNeeded = false
        panel.hidesOnDeactivate = false
        panel.hasShadow = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.acceptsMouseMovedEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        panelContainerView.wantsLayer = true
        panelContainerView.layer?.cornerRadius = AppCornerRadius.panel
        panelContainerView.layer?.masksToBounds = true

        panelContentView.translatesAutoresizingMaskIntoConstraints = false
        if #available(macOS 26.0, *), let glassClass = NSClassFromString("NSGlassEffectView"), panelContainerView.isKind(of: glassClass) {
            panelContainerView.setValue(panelContentView, forKey: "contentView")
        } else {
            panelContainerView.addSubview(panelContentView)
            NSLayoutConstraint.activate([
                panelContentView.leadingAnchor.constraint(equalTo: panelContainerView.leadingAnchor),
                panelContentView.trailingAnchor.constraint(equalTo: panelContainerView.trailingAnchor),
                panelContentView.topAnchor.constraint(equalTo: panelContainerView.topAnchor),
                panelContentView.bottomAnchor.constraint(equalTo: panelContainerView.bottomAnchor),
            ])
        }

        rootView.translatesAutoresizingMaskIntoConstraints = false
        panelContentView.addSubview(rootView)
        NSLayoutConstraint.activate([
            rootView.leadingAnchor.constraint(equalTo: panelContentView.leadingAnchor),
            rootView.trailingAnchor.constraint(equalTo: panelContentView.trailingAnchor),
            rootView.topAnchor.constraint(equalTo: panelContentView.topAnchor),
            rootView.bottomAnchor.constraint(equalTo: panelContentView.bottomAnchor),
        ])

        panel.contentView = panelContainerView
    }

    private static func makePanelContainerView() -> NSView {
        if #available(macOS 26.0, *), let glassClass = NSClassFromString("NSGlassEffectView") as? NSView.Type {
            let glassView = glassClass.init(frame: .zero)
            glassView.setValue(AppCornerRadius.panel, forKey: "cornerRadius")
            glassView.setValue(0, forKey: "style")
            return glassView
        }

        let effectView = NSVisualEffectView(frame: .zero)
        effectView.material = .popover
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        return effectView
    }

    private func configureButton() {
        guard let statusButton = statusItem.button else { return }

        statusItem.length = NSStatusItem.variableLength
        statusButton.font = NSFont.systemFont(ofSize: StatusBarConfig.marqueeFontSize, weight: .regular)
        statusButton.imagePosition = .imageLeading
        statusButton.imageHugsTitle = true
        statusButton.title = statusTitle(StatusBarConfig.fallbackText)
        statusButton.image = statusImage(named: StatusBarConfig.fallbackIconName)
        statusButton.contentTintColor = nil
        statusButton.action = #selector(togglePopover(_:))
        statusButton.target = self
        statusButton.sendAction(on: [.leftMouseUp])
        statusButton.addCursorRect(statusButton.bounds, cursor: .pointingHand)
    }

    private func configureContextMenu() {
        let menu = PlexStatusMenu()
        menu.delegate = self
    }

    private func configureOutsideClickMonitoring() {
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in
                self?.hidePanelIfUnpinned()
            }
        }
    }

    private func hidePanelIfUnpinned() {
        guard panel.isVisible, !isPanelPinned else { return }
        hidePanel()
    }

    private func bind(appState: AppState) {
        Publishers.MergeMany(
            appState.authService.objectWillChange.eraseToAnyPublisher(),
            appState.settingsStore.objectWillChange.eraseToAnyPublisher(),
            appState.libraryStore.objectWillChange.eraseToAnyPublisher(),
            appState.playbackEngine.objectWillChange.eraseToAnyPublisher()
        )
            .sink { [weak self, weak appState] _ in
                guard let self, let appState else { return }
                Task { @MainActor in
                    if !appState.isConfigured {
                        self.isPanelPinned = false
                    }
                    self.applyThemePreference(appState.themePreference)
                    self.updateStatus(iconName: appState.statusIconName, text: appState.statusLine)
                }
            }
            .store(in: &cancellables)

        appState.libraryStore.$shouldPresentInitialLoadFailure
            .filter { $0 }
            .sink { [weak self, weak appState] _ in
                guard let self, let appState else { return }
                self.showPanel()
                appState.didPresentInitialLoadFailure()
            }
            .store(in: &cancellables)
    }

    private func applyThemePreference(_ preference: AppThemePreference) {
        guard currentThemePreference != preference else { return }
        currentThemePreference = preference

        let appearance: NSAppearance?
        switch preference {
        case .system:
            appearance = nil
        case .light:
            appearance = NSAppearance(named: .aqua)
        case .dark:
            appearance = NSAppearance(named: .darkAqua)
        }

        panel.appearance = appearance
        panelContainerView.appearance = appearance
        rootView.appearance = appearance
    }

    private func updateStatus(iconName: String, text: String) {
        let resolvedText = resolvedStatusText(from: text)
        let resolvedIconName = resolvedStatusIconName(from: iconName, text: resolvedText)

        if !hasRenderedResolvedStatus,
           resolvedText == StatusBarConfig.fallbackText,
           resolvedIconName == StatusBarConfig.fallbackIconName {
            applyFallbackStatus()
            return
        }

        guard resolvedIconName != currentStatusIconName || resolvedText != currentStatusText else { return }

        currentStatusIconName = resolvedIconName
        currentStatusText = resolvedText
        applyStatusButton(iconName: resolvedIconName, text: resolvedText)
        hasRenderedResolvedStatus = true
    }

    private func applyFallbackStatus() {
        currentStatusIconName = StatusBarConfig.fallbackIconName
        currentStatusText = StatusBarConfig.fallbackText
        applyStatusButton(iconName: StatusBarConfig.fallbackIconName, text: StatusBarConfig.fallbackText)
    }

    private func applyStatusButton(iconName: String, text: String) {
        guard let statusButton = statusItem.button else { return }

        statusItem.length = NSStatusItem.variableLength
        statusButton.image = statusImage(named: iconName)
        statusButton.title = statusTitle(text)
    }

    private func statusImage(named iconName: String) -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: StatusBarConfig.iconFontSize, weight: .medium)
        guard let image = NSImage(systemSymbolName: iconName, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
        else { return nil }

        let shiftedImage = NSImage(size: image.size, flipped: false) { rect in
            image.draw(in: rect.offsetBy(dx: 0, dy: StatusBarConfig.iconVerticalOffset))
            return true
        }

        shiftedImage.isTemplate = true
        return shiftedImage
    }

    private func statusTitle(_ text: String) -> String {
        StatusBarConfig.iconTitleSpacing + text
    }

    private func resolvedStatusText(from text: String) -> String {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedText.isEmpty || trimmedText == TrackMetadata.placeholder.trackName {
            return StatusBarConfig.fallbackText
        }

        return trimmedText
    }

    private func resolvedStatusIconName(from iconName: String, text: String) -> String {
        text == StatusBarConfig.fallbackText ? StatusBarConfig.fallbackIconName : iconName
    }

    @objc
    private func playPauseAction() {
        appState.togglePlayback()
    }

    @objc
    private func previousTrackAction() {
        appState.previousTrack()
    }

    @objc
    private func nextTrackAction() {
        appState.nextTrack()
    }

    @objc
    fileprivate func toggleShuffleAction(_ sender: NSMenuItem) {
        appState.toggleShuffle()
        sender.title = appState.isShuffleEnabled ? "Disable Shuffle" : "Enable Shuffle"
    }

    @objc
    private func playStationAction(_ sender: NSMenuItem) {
        guard let station = sender.representedObject as? MediaStation else { return }
        appState.playStation(station)
    }

    @objc
    private func togglePopover(_ sender: Any?) {
        if panel.isVisible {
            hidePanel()
        } else {
            showPanel()
        }
    }

    private func showPanel() {
        isPanelPinned = false
        isPanelHiding = false
        panelState.openCount += 1

        let targetFrame = panelTargetFrame()
        var initialFrame = targetFrame
        initialFrame.origin.y += StatusBarConfig.panelAnimationOffset

        panel.alphaValue = 0
        panel.setFrame(initialFrame, display: false)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)

        Task { @MainActor in
            await appState.checkForUpdatesOnFirstPanelOpen()
        }

        Task { @MainActor in
            await Task.yield()
            await NSAnimationContext.runAnimationGroup { context in
                context.duration = StatusBarConfig.panelAnimationDuration
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().alphaValue = 1
                panel.animator().setFrame(targetFrame, display: true)
            }
        }
    }

    private func hidePanel() {
        guard panel.isVisible, !isPanelHiding else { return }

        isPanelHiding = true
        let startFrame = panel.frame
        var targetFrame = startFrame
        targetFrame.origin.y += StatusBarConfig.panelAnimationOffset

        NSAnimationContext.runAnimationGroup { context in
            context.duration = StatusBarConfig.panelAnimationDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().alphaValue = 0
            panel.animator().setFrame(targetFrame, display: true)
        } completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.panel.orderOut(nil)
                self.panel.alphaValue = 1
                self.panel.setFrame(startFrame, display: false)
                self.isPanelHiding = false
            }
        }
    }

    private func positionPanel() {
        panel.setFrame(panelTargetFrame(), display: true)
    }

    private func positionPanelIfVisible() {
        guard panel.isVisible else { return }
        positionPanel()
    }

    private func panelTargetFrame() -> NSRect {
        guard let screen = statusItem.button?.window?.screen ?? NSScreen.main else {
            return panel.frame
        }

        let visibleFrame = screen.visibleFrame
        var frame = panel.frame
        switch appState.settingsStore.settings.panelPosition {
        case .screenCorner:
            frame.origin.x = visibleFrame.maxX - frame.width - StatusBarConfig.topRightScreenMargin.width
            frame.origin.y = visibleFrame.maxY - frame.height - StatusBarConfig.topRightScreenMargin.height
        case .menuBarItem:
            frame.origin = menuBarItemPanelOrigin(
                for: frame,
                visibleFrame: visibleFrame
            ) ?? screenCornerPanelOrigin(for: frame, visibleFrame: visibleFrame)
        }
        return frame
    }

    private func screenCornerPanelOrigin(for frame: NSRect, visibleFrame: NSRect) -> NSPoint {
        NSPoint(
            x: visibleFrame.maxX - frame.width - StatusBarConfig.topRightScreenMargin.width,
            y: visibleFrame.maxY - frame.height - StatusBarConfig.topRightScreenMargin.height
        )
    }

    private func menuBarItemPanelOrigin(for frame: NSRect, visibleFrame: NSRect) -> NSPoint? {
        guard let statusButton = statusItem.button,
              let statusWindow = statusButton.window else {
            return nil
        }

        let buttonFrameInWindow = statusButton.convert(statusButton.bounds, to: nil)
        let buttonFrameInScreen = statusWindow.convertToScreen(buttonFrameInWindow)
        let margin = StatusBarConfig.topRightScreenMargin
        let unclampedX = buttonFrameInScreen.midX - (frame.width / 2)
        let minX = visibleFrame.minX + margin.width
        let maxX = visibleFrame.maxX - frame.width - margin.width
        let topY = min(buttonFrameInScreen.minY, visibleFrame.maxY)

        return NSPoint(
            x: min(max(unclampedX, minX), maxX),
            y: topY - frame.height - margin.height
        )
    }
}

private final class MenuBarPanel: NSPanel {
    override var canBecomeKey: Bool {
        true
    }

    override var canBecomeMain: Bool {
        true
    }
}

// MARK: - NSMenuDelegate

private final class PlexStatusMenu: NSMenu {
    override func cancelTracking() {
        if let item = highlightedItem, item.action == #selector(StatusItemController.toggleShuffleAction(_:)) {
            return
        }
        super.cancelTracking()
    }

    override func cancelTrackingWithoutAnimation() {
        if let item = highlightedItem, item.action == #selector(StatusItemController.toggleShuffleAction(_:)) {
            return
        }
        super.cancelTrackingWithoutAnimation()
    }
}

extension StatusItemController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let isPlaying = appState.playbackState == .playing
        let playPauseItem = menu.addItem(withTitle: isPlaying ? "Pause" : "Play", action: #selector(playPauseAction), keyEquivalent: "")
        playPauseItem.target = self
        playPauseItem.image = NSImage(systemSymbolName: isPlaying ? "pause.fill" : "play.fill", accessibilityDescription: nil)

        let previousItem = menu.addItem(withTitle: "Previous", action: #selector(previousTrackAction), keyEquivalent: "")
        previousItem.target = self
        previousItem.image = NSImage(systemSymbolName: "backward.fill", accessibilityDescription: nil)
        previousItem.isEnabled = appState.canGoToPreviousTrack

        let nextItem = menu.addItem(withTitle: "Next", action: #selector(nextTrackAction), keyEquivalent: "")
        nextItem.target = self
        nextItem.image = NSImage(systemSymbolName: "forward.fill", accessibilityDescription: nil)
        nextItem.isEnabled = appState.canGoToNextTrack

        let shuffleTitle = appState.isShuffleEnabled ? "Disable Shuffle" : "Enable Shuffle"
        let shuffleItem = menu.addItem(withTitle: shuffleTitle, action: #selector(toggleShuffleAction(_:)), keyEquivalent: "")
        shuffleItem.target = self
        shuffleItem.image = NSImage(systemSymbolName: "shuffle", accessibilityDescription: nil)
        shuffleItem.isEnabled = appState.canShuffle

        let stations = appState.stations.prefix(2)
        if !stations.isEmpty {
            menu.addItem(.separator())
            for station in stations {
                let item = menu.addItem(withTitle: station.title, action: #selector(playStationAction(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = station
                item.image = NSImage(systemSymbolName: "radio.fill", accessibilityDescription: nil)
            }
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "").target = NSApp
    }
}
