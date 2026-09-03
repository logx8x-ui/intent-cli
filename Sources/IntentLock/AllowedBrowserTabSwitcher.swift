import AppKit
import Foundation
import IntentCore

final class AllowedBrowserTabSwitcher {
    private struct Item {
        let tab: BrowserTabItem
        let title: String
        let subtitle: String
        let icon: NSImage
    }

    private let stateLock = NSLock()
    private var browserBundleIdentifier: String?
    private var items: [Item] = []
    private var selectedIndex = 0
    private var visible = false
    private var panelController: BrowserTabSwitcherPanelController?

    var isVisible: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return visible
    }

    @discardableResult
    func advance(browserBundleIdentifier: String, reverse: Bool) -> Bool {
        stateLock.lock()
        if !visible || self.browserBundleIdentifier != browserBundleIdentifier {
            items = makeItems(browserBundleIdentifier: browserBundleIdentifier)
            guard items.count > 1 else {
                visible = false
                stateLock.unlock()
                return false
            }
            self.browserBundleIdentifier = browserBundleIdentifier
            visible = true
            selectedIndex = reverse ? items.count - 1 : 1
        } else {
            let delta = reverse ? -1 : 1
            selectedIndex = (selectedIndex + delta + items.count) % items.count
        }
        let panelItems = items.map {
            BrowserTabSwitcherPanelController.Item(
                title: $0.title,
                subtitle: $0.subtitle,
                icon: $0.icon
            )
        }
        let index = selectedIndex
        stateLock.unlock()

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let controller = self.panelController ?? BrowserTabSwitcherPanelController(
                onHover: { [weak self] index in self?.select(index: index) },
                onClick: { [weak self] index in
                    self?.select(index: index)
                    self?.commit()
                }
            )
            self.panelController = controller
            controller.show(items: panelItems, selectedIndex: index)
        }
        return true
    }

    func commit() {
        stateLock.lock()
        guard visible,
              items.indices.contains(selectedIndex),
              let browserBundleIdentifier else {
            stateLock.unlock()
            return
        }
        let tab = items[selectedIndex].tab
        visible = false
        items = []
        stateLock.unlock()

        let command = BrowserTabCommand(tabID: tab.id, windowID: tab.windowID)
        try? BrowserTabCommandStore(browserBundleIdentifier: browserBundleIdentifier).write(command)
        DispatchQueue.main.async { [weak self] in
            self?.panelController?.hide()
            NSWorkspace.shared.runningApplications
                .first(where: { $0.bundleIdentifier == browserBundleIdentifier })?
                .activate(options: [.activateIgnoringOtherApps])
        }
    }

    func cancel() {
        stateLock.lock()
        visible = false
        items = []
        stateLock.unlock()
        DispatchQueue.main.async { [weak self] in
            self?.panelController?.hide()
        }
    }

    private func select(index: Int) {
        stateLock.lock()
        guard visible, items.indices.contains(index) else {
            stateLock.unlock()
            return
        }
        selectedIndex = index
        stateLock.unlock()
        DispatchQueue.main.async { [weak self] in
            self?.panelController?.updateSelection(index)
        }
    }

    private func makeItems(browserBundleIdentifier: String) -> [Item] {
        guard let snapshot = BrowserTabSnapshotStore(
            browserBundleIdentifier: browserBundleIdentifier
        ).load(maxAge: 10) else {
            return []
        }

        let icon = browserIcon(bundleIdentifier: browserBundleIdentifier)
        let orderedTabs = snapshot.tabs.sorted { lhs, rhs in
            if lhs.active != rhs.active { return lhs.active }
            if lhs.windowID != rhs.windowID { return lhs.windowID < rhs.windowID }
            return lhs.index < rhs.index
        }
        return orderedTabs.map { tab in
            Item(
                tab: tab,
                title: tab.title.isEmpty ? "New Tab" : tab.title,
                subtitle: URL(string: tab.url)?.host ?? "Search tab",
                icon: icon
            )
        }
    }

    private func browserIcon(bundleIdentifier: String) -> NSImage {
        guard let applicationURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: bundleIdentifier
        ) else {
            return NSImage(systemSymbolName: "globe", accessibilityDescription: nil) ?? NSImage()
        }
        return NSWorkspace.shared.icon(forFile: applicationURL.path)
    }
}

@MainActor
private final class BrowserTabSwitcherPanelController {
    struct Item {
        let title: String
        let subtitle: String
        let icon: NSImage
    }

    private let panel: NSPanel
    private let content = NSStackView()
    private let onHover: (Int) -> Void
    private let onClick: (Int) -> Void
    private var itemViews: [BrowserTabSwitcherItemView] = []

    init(onHover: @escaping (Int) -> Void, onClick: @escaping (Int) -> Void) {
        self.onHover = onHover
        self.onClick = onClick
        panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.acceptsMouseMovedEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]

        let container = NSVisualEffectView()
        container.material = .hudWindow
        container.blendingMode = .behindWindow
        container.state = .active
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(calibratedWhite: 0.055, alpha: 0.58).cgColor
        container.layer?.cornerRadius = 22
        container.layer?.borderWidth = 1
        container.layer?.borderColor = NSColor(calibratedWhite: 1, alpha: 0.20).cgColor

        content.orientation = .horizontal
        content.alignment = .centerY
        content.distribution = .fillEqually
        content.spacing = 12
        content.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            content.topAnchor.constraint(equalTo: container.topAnchor, constant: 18),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -18)
        ])
        panel.contentView = container
    }

    func show(items: [Item], selectedIndex: Int) {
        content.arrangedSubviews.forEach {
            content.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        itemViews = []
        for (index, item) in items.enumerated() {
            let view = BrowserTabSwitcherItemView(
                item: item,
                index: index,
                onHover: onHover,
                onClick: onClick
            )
            view.setSelected(index == selectedIndex)
            itemViews.append(view)
            content.addArrangedSubview(view)
        }

        let itemWidth: CGFloat = 156
        let width = min(CGFloat(items.count) * itemWidth + 40, 1_020)
        let size = NSSize(width: max(width, 340), height: 166)
        let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main
        let visibleFrame = screen?.visibleFrame ?? .zero
        panel.setFrame(
            NSRect(
                x: visibleFrame.midX - size.width / 2,
                y: visibleFrame.midY - size.height / 2,
                width: size.width,
                height: size.height
            ),
            display: true
        )
        panel.orderFrontRegardless()
    }

    func updateSelection(_ selectedIndex: Int) {
        for (index, view) in itemViews.enumerated() {
            view.setSelected(index == selectedIndex)
        }
    }

    func hide() {
        panel.orderOut(nil)
    }
}

@MainActor
private final class BrowserTabSwitcherItemView: NSView {
    private let index: Int
    private let onHover: (Int) -> Void
    private let onClick: (Int) -> Void
    private var trackingAreaReference: NSTrackingArea?

    init(
        item: BrowserTabSwitcherPanelController.Item,
        index: Int,
        onHover: @escaping (Int) -> Void,
        onClick: @escaping (Int) -> Void
    ) {
        self.index = index
        self.onHover = onHover
        self.onClick = onClick
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 16

        let image = NSImageView(image: item.icon)
        image.imageScaling = .scaleProportionallyUpOrDown
        image.translatesAutoresizingMaskIntoConstraints = false
        let title = NSTextField(labelWithString: item.title)
        title.textColor = .white
        title.font = .systemFont(ofSize: 11, weight: .semibold)
        title.alignment = .center
        title.lineBreakMode = .byTruncatingTail
        title.translatesAutoresizingMaskIntoConstraints = false
        let subtitle = NSTextField(labelWithString: item.subtitle)
        subtitle.textColor = NSColor.white.withAlphaComponent(0.55)
        subtitle.font = .systemFont(ofSize: 9, weight: .regular)
        subtitle.alignment = .center
        subtitle.lineBreakMode = .byTruncatingMiddle
        subtitle.translatesAutoresizingMaskIntoConstraints = false
        addSubview(image)
        addSubview(title)
        addSubview(subtitle)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 144),
            heightAnchor.constraint(equalToConstant: 128),
            image.widthAnchor.constraint(equalToConstant: 58),
            image.heightAnchor.constraint(equalToConstant: 58),
            image.centerXAnchor.constraint(equalTo: centerXAnchor),
            image.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            title.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            title.topAnchor.constraint(equalTo: image.bottomAnchor, constant: 8),
            subtitle.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            subtitle.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 2)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaReference { removeTrackingArea(trackingAreaReference) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaReference = area
    }

    override func mouseEntered(with event: NSEvent) {
        onHover(index)
    }

    override func mouseDown(with event: NSEvent) {
        onClick(index)
    }

    func setSelected(_ selected: Bool) {
        layer?.backgroundColor = selected
            ? NSColor(calibratedWhite: 1, alpha: 0.13).cgColor
            : NSColor.clear.cgColor
        layer?.borderWidth = selected ? 1.2 : 0
        layer?.borderColor = NSColor(calibratedWhite: 1, alpha: 0.52).cgColor
    }
}
