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

@MainActor
final class StatusItemController {
    private let initialStatusIconName = PlaybackState.buffering.statusSystemImageName
    private let initialStatusText = "Initializing..."
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let iconView = NSImageView(frame: .zero)
    private let marqueeView = StatusMarqueeView(frame: .zero)
    private let stackView = NSStackView(frame: .zero)
    private let panelContainerView: NSView
    private let panelContentView = NSView(frame: .zero)
    private let rootView: NSHostingView<MenuBarRootView>
    private let panel: NSPanel
    private var cancellables = Set<AnyCancellable>()
    private var globalMouseMonitor: Any?
    private var isSettingsTabSelected = false
    private let horizontalPadding: CGFloat = 12
    private let iconWidth: CGFloat = 12
    private let iconTextGap: CGFloat = 8
    private let textContentPadding: CGFloat = 8
    private var hasRenderedResolvedStatus = false
    private let topRightScreenMargin = NSSize(width: 4, height: 4)
    private let panelSize = NSSize(width: 460, height: 520)

    init(appState: AppState) {
        panelContainerView = Self.makePanelContainerView()
        rootView = NSHostingView(rootView: MenuBarRootView(appState: appState, onClose: {}, onTabChange: { _ in }))
        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        configurePanel()
        rootView.rootView = makeRootView(appState: appState)
        configureButton()
        configureOutsideClickMonitoring()
        applyThemePreference(appState.themePreference)
        applyFallbackStatus()
        bind(appState: appState)
        updateStatus(iconName: appState.statusIconName, text: appState.statusLine)
    }

    private func configurePanel() {
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.hasShadow = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        panelContainerView.wantsLayer = true
        panelContainerView.layer?.cornerRadius = AppCornerRadius.panel
        panelContainerView.layer?.masksToBounds = true

        panelContentView.translatesAutoresizingMaskIntoConstraints = false
        if #available(macOS 26.0, *), let glassView = panelContainerView as? NSGlassEffectView {
            glassView.contentView = panelContentView
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
        if #available(macOS 26.0, *) {
            let glassView = NSGlassEffectView(frame: .zero)
            glassView.cornerRadius = AppCornerRadius.panel
            glassView.style = .regular
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

        iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
        iconView.contentTintColor = .labelColor
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.setContentHuggingPriority(.required, for: .horizontal)
        iconView.setContentCompressionResistancePriority(.required, for: .horizontal)

        marqueeView.translatesAutoresizingMaskIntoConstraints = false
        marqueeView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        marqueeView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        stackView.orientation = .horizontal
        stackView.alignment = .centerY
        stackView.spacing = 8
        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.addArrangedSubview(iconView)
        stackView.addArrangedSubview(marqueeView)

        statusButton.addSubview(stackView)

        NSLayoutConstraint.activate([
            stackView.leadingAnchor.constraint(equalTo: statusButton.leadingAnchor, constant: 6),
            stackView.trailingAnchor.constraint(equalTo: statusButton.trailingAnchor, constant: -6),
            stackView.centerYAnchor.constraint(equalTo: statusButton.centerYAnchor),

            iconView.widthAnchor.constraint(equalToConstant: 12),
            iconView.heightAnchor.constraint(equalToConstant: 12),
            marqueeView.heightAnchor.constraint(equalToConstant: 16),
            marqueeView.widthAnchor.constraint(greaterThanOrEqualToConstant: 24),
        ])
    }

    private func configureOutsideClickMonitoring() {
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in
                self?.hidePanelIfUnpinned()
            }
        }
    }

    private func hidePanelIfUnpinned() {
        guard panel.isVisible, !isSettingsTabSelected else { return }
        panel.orderOut(nil)
    }

    private func bind(appState: AppState) {
        appState.objectWillChange
            .sink { [weak self, weak appState] _ in
                guard let self, let appState else { return }
                Task { @MainActor in
                    if !appState.isAuthenticated {
                        self.isSettingsTabSelected = false
                    }
                    self.applyThemePreference(appState.themePreference)
                    self.rootView.rootView = self.makeRootView(appState: appState)
                    self.updateStatus(iconName: appState.statusIconName, text: appState.statusLine)
                }
            }
            .store(in: &cancellables)

        appState.$shouldPresentInitialLoadFailure
            .filter { $0 }
            .sink { [weak self, weak appState] _ in
                guard let self, let appState else { return }
                self.showPanel()
                appState.didPresentInitialLoadFailure()
            }
            .store(in: &cancellables)
    }

    private func makeRootView(appState: AppState) -> MenuBarRootView {
        MenuBarRootView(
            appState: appState,
            onClose: { [weak self] in
                self?.panel.orderOut(nil)
            },
            onTabChange: { [weak self] isSettingsTabSelected in
                self?.isSettingsTabSelected = isSettingsTabSelected
            }
        )
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
           resolvedText == initialStatusText,
           resolvedIconName == initialStatusIconName {
            applyFallbackStatus()
            return
        }

        iconView.image = NSImage(systemSymbolName: resolvedIconName, accessibilityDescription: nil)
        marqueeView.text = resolvedText
        updateStatusItemLength()
        hasRenderedResolvedStatus = true
    }

    private func applyFallbackStatus() {
        iconView.image = NSImage(systemSymbolName: initialStatusIconName, accessibilityDescription: nil)
        marqueeView.text = initialStatusText
        updateStatusItemLength()
    }

    private func resolvedStatusText(from text: String) -> String {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedText.isEmpty || trimmedText == TrackMetadata.placeholder.trackName {
            return initialStatusText
        }

        return trimmedText
    }

    private func resolvedStatusIconName(from iconName: String, text: String) -> String {
        text == initialStatusText ? initialStatusIconName : iconName
    }

    @objc
    private func togglePopover(_ sender: Any?) {
        if panel.isVisible {
            panel.orderOut(sender)
        } else {
            showPanel()
        }
    }

    private func showPanel() {
        positionPanel()
        panel.orderFrontRegardless()
    }

    private func updateStatusItemLength() {
        let targetLength = horizontalPadding + iconWidth + iconTextGap + marqueeView.visibleWidth + textContentPadding

        statusItem.length = targetLength

        if panel.isVisible {
            positionPanel()
        }
    }

    private func positionPanel() {
        guard let screen = statusItem.button?.window?.screen ?? NSScreen.main else {
            return
        }

        let visibleFrame = screen.visibleFrame
        var frame = panel.frame
        frame.origin.x = visibleFrame.maxX - frame.width - topRightScreenMargin.width
        frame.origin.y = visibleFrame.maxY - frame.height - topRightScreenMargin.height
        panel.setFrame(frame, display: true)
    }
}

private final class StatusMarqueeView: NSView {
    var text: String = "" {
        didSet {
            guard text != oldValue else { return }
            textLabel.stringValue = text
            needsLayout = true
            invalidateIntrinsicContentSize()
        }
    }

    private let font = NSFont.systemFont(ofSize: 13, weight: .regular)
    private let horizontalTextPadding: CGFloat = 4
    private let textLabel = NSTextField(labelWithString: "")

    var visibleWidth: CGFloat {
        max(24, textWidth + (horizontalTextPadding * 2))
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
