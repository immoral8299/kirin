import AppKit
import Combine
import QuartzCore
import SwiftUI

fileprivate enum StatusBarConfig {
    static let fallbackIconName = PlaybackStateIcon.statusSystemImageName(for: .buffering)
    static let fallbackText = "Initializing..."
    static let horizontalPadding: CGFloat = 12
    static let iconWidth: CGFloat = 12
    static let iconTextGap: CGFloat = 8
    static let textContentPadding: CGFloat = 8
    static let topRightScreenMargin = NSSize(width: 4, height: 4)
    static let panelSize = NSSize(width: 460, height: 520)
    static let iconFontSize: CGFloat = 11
    static let marqueeFontSize: CGFloat = 13
    static let marqueeMinVisibleWidth: CGFloat = 24
    static let marqueeHorizontalTextPadding: CGFloat = 2
    static let marqueeHeight: CGFloat = 16
    static let stackViewSpacing: CGFloat = 8
    static let buttonHorizontalMargin: CGFloat = 6
    static let panelAnimationDuration: TimeInterval = 0.16
    static let panelAnimationOffset: CGFloat = 10
}

@MainActor
final class StatusItemController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let appState: AppState
    private let iconView = NSImageView(frame: .zero)
    private let marqueeView = StatusMarqueeView(frame: .zero)
    private let stackView = NSStackView(frame: .zero)
    private let panelContainerView: NSView
    private let panelContentView = NSView(frame: .zero)
    private var rootView: NSHostingView<MenuBarRootView>!
    private let panel: MenuBarPanel
    private var cancellables = Set<AnyCancellable>()
    private var globalMouseMonitor: Any?
    private var isPanelPinned = false
    private var isPanelHiding = false
    private var hasRenderedResolvedStatus = false

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

        statusButton.title = ""
        statusButton.image = nil
        statusButton.action = #selector(togglePopover(_:))
        statusButton.target = self
        statusButton.sendAction(on: [.leftMouseUp])
        statusButton.addCursorRect(statusButton.bounds, cursor: .pointingHand)

        iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: StatusBarConfig.iconFontSize, weight: .medium)
        iconView.contentTintColor = .labelColor
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.setContentHuggingPriority(.required, for: .horizontal)
        iconView.setContentCompressionResistancePriority(.required, for: .horizontal)

        marqueeView.translatesAutoresizingMaskIntoConstraints = false
        marqueeView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        marqueeView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        stackView.orientation = .horizontal
        stackView.alignment = .centerY
        stackView.spacing = StatusBarConfig.stackViewSpacing
        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.addArrangedSubview(iconView)
        stackView.addArrangedSubview(marqueeView)

        statusButton.addSubview(stackView)

        NSLayoutConstraint.activate([
            stackView.leadingAnchor.constraint(equalTo: statusButton.leadingAnchor, constant: StatusBarConfig.buttonHorizontalMargin),
            stackView.trailingAnchor.constraint(equalTo: statusButton.trailingAnchor, constant: -StatusBarConfig.buttonHorizontalMargin),
            stackView.centerYAnchor.constraint(equalTo: statusButton.centerYAnchor),

            iconView.widthAnchor.constraint(equalToConstant: StatusBarConfig.iconWidth),
            iconView.heightAnchor.constraint(equalToConstant: StatusBarConfig.iconWidth),
            marqueeView.heightAnchor.constraint(equalToConstant: StatusBarConfig.marqueeHeight),
            marqueeView.widthAnchor.constraint(greaterThanOrEqualToConstant: StatusBarConfig.marqueeMinVisibleWidth),
        ])
    }

    private func configureContextMenu() {
        let menu = PlexStatusMenu()
        menu.delegate = self
        marqueeView.menu = menu
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

        iconView.image = NSImage(systemSymbolName: resolvedIconName, accessibilityDescription: nil)
        marqueeView.text = resolvedText
        updateStatusItemLength()
        hasRenderedResolvedStatus = true
    }

    private func applyFallbackStatus() {
        iconView.image = NSImage(systemSymbolName: StatusBarConfig.fallbackIconName, accessibilityDescription: nil)
        marqueeView.text = StatusBarConfig.fallbackText
        updateStatusItemLength()
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

    private func updateStatusItemLength() {
        let targetLength = StatusBarConfig.horizontalPadding + StatusBarConfig.iconWidth + StatusBarConfig.iconTextGap + marqueeView.visibleWidth + StatusBarConfig.textContentPadding

        statusItem.length = targetLength
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

final class StatusMarqueeView: NSView {
    var text: String = "" {
        didSet {
            guard text != oldValue else { return }
            textLabel.stringValue = text
            needsLayout = true
            invalidateIntrinsicContentSize()
        }
    }

    private let font = NSFont.systemFont(ofSize: StatusBarConfig.marqueeFontSize, weight: .regular)
    private let horizontalTextPadding = StatusBarConfig.marqueeHorizontalTextPadding
    private let textLabel = NSTextField(labelWithString: "")

    var visibleWidth: CGFloat {
        max(StatusBarConfig.marqueeMinVisibleWidth, textWidth + horizontalTextPadding)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true

        textLabel.font = font
        textLabel.textColor = .labelColor
        textLabel.backgroundColor = .clear
        textLabel.lineBreakMode = .byTruncatingTail
        textLabel.translatesAutoresizingMaskIntoConstraints = true
        textLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        textLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(textLabel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func layout() {
        super.layout()

        textLabel.frame = NSRect(
            x: horizontalTextPadding,
            y: verticallyCenteredY(for: textLabel),
            width: max(0, bounds.width - (horizontalTextPadding * 2)),
            height: textLabel.fittingSize.height
        )
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 16)
    }

    private var textWidth: CGFloat {
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        return ceil((text as NSString).size(withAttributes: attributes).width)
    }

    private func verticallyCenteredY(for label: NSTextField) -> CGFloat {
        floor((bounds.height - label.fittingSize.height) / 2)
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
    }
}
