import AppKit
import Foundation

final class AllowedAppSwitcher {
    private struct Item {
        let application: NSRunningApplication
        let name: String
        let icon: NSImage
    }

    private let allowedBundleIdentifiers: Set<String>
    private let stateLock = NSLock()
    private var activationOrder: [String] = []
    private var items: [Item] = []
    private var selectedIndex = 0
    private var visible = false
    private var panelController: AllowedAppSwitcherPanelController?

    init(allowedBundleIdentifiers: Set<String>) {
        self.allowedBundleIdentifiers = allowedBundleIdentifiers
    }

    var isVisible: Bool {
        stateLock.withLock { visible }
    }

    func recordActivation(bundleIdentifier: String?) {
        guard let bundleIdentifier,
              allowedBundleIdentifiers.contains(bundleIdentifier) else {
            return
        }

        stateLock.withLock {
            activationOrder.removeAll { $0 == bundleIdentifier }
            activationOrder.insert(bundleIdentifier, at: 0)
        }
    }

    func advance(reverse: Bool) {
        let snapshot: ([AllowedAppSwitcherPanelController.Item], Int)? = stateLock.withLock {
            if !visible {
                items = makeItems()
                guard items.count > 1 else { return nil }
                visible = true
                selectedIndex = reverse ? items.count - 1 : 1
            } else if !items.isEmpty {
                let delta = reverse ? -1 : 1
                selectedIndex = (selectedIndex + delta + items.count) % items.count
            }

            let panelItems = items.map {
                AllowedAppSwitcherPanelController.Item(name: $0.name, icon: $0.icon)
            }
            return (panelItems, selectedIndex)
        }

        guard let snapshot else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let controller = self.panelController ?? AllowedAppSwitcherPanelController(
                onHover: { [weak self] index in
                    self?.select(index: index)
                }
            )
            self.panelController = controller
            controller.show(items: snapshot.0, selectedIndex: snapshot.1)
        }
    }

    private func select(index: Int) {
        let selectedIndex: Int? = stateLock.withLock {
            guard visible, items.indices.contains(index) else { return nil }
            self.selectedIndex = index
            return index
        }

        guard let selectedIndex else { return }
        DispatchQueue.main.async { [weak self] in
            self?.panelController?.updateSelection(selectedIndex)
        }
    }

    func commit() {
        let application: NSRunningApplication? = stateLock.withLock {
            guard visible, items.indices.contains(selectedIndex) else { return nil }
            visible = false
            return items[selectedIndex].application
        }

        DispatchQueue.main.async { [weak self] in
            self?.panelController?.hide()
            application?.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        }
    }

    func cancel() {
        stateLock.withLock {
            visible = false
            items = []
        }
        DispatchQueue.main.async { [weak self] in
            self?.panelController?.hide()
        }
    }

    private func makeItems() -> [Item] {
        let running = NSWorkspace.shared.runningApplications.filter { application in
            guard let bundleIdentifier = application.bundleIdentifier else { return false }
            return allowedBundleIdentifiers.contains(bundleIdentifier)
                && application.activationPolicy == .regular
                && !application.isTerminated
        }

        let frontmostIdentifier = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        var orderedIdentifiers: [String] = []
        if let frontmostIdentifier,
           allowedBundleIdentifiers.contains(frontmostIdentifier) {
            orderedIdentifiers.append(frontmostIdentifier)
        }
        orderedIdentifiers.append(contentsOf: activationOrder.filter { !orderedIdentifiers.contains($0) })
        orderedIdentifiers.append(contentsOf: running.compactMap(\.bundleIdentifier).filter { !orderedIdentifiers.contains($0) })

        return orderedIdentifiers.compactMap { bundleIdentifier in
            guard let application = running.first(where: { $0.bundleIdentifier == bundleIdentifier }) else {
                return nil
            }
            return Item(
                application: application,
                name: application.localizedName ?? bundleIdentifier,
                icon: application.icon ?? NSImage(systemSymbolName: "app", accessibilityDescription: nil) ?? NSImage()
            )
        }
    }
}

private final class AllowedAppSwitcherPanelController {
    struct Item {
        let name: String
        let icon: NSImage
    }

    private let panel: NSPanel
    private let content = NSStackView()
    private let onHover: (Int) -> Void
    private var itemViews: [AllowedAppSwitcherItemView] = []

    init(onHover: @escaping (Int) -> Void) {
        self.onHover = onHover
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

        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(calibratedWhite: 0.075, alpha: 0.96).cgColor
        container.layer?.cornerRadius = 18
        container.layer?.borderWidth = 1
        container.layer?.borderColor = NSColor(calibratedWhite: 1, alpha: 0.18).cgColor

        content.orientation = .horizontal
        content.alignment = .centerY
        content.distribution = .fillEqually
        content.spacing = 12
        content.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            content.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16)
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
            let itemView = makeItemView(item, index: index, selected: index == selectedIndex)
            itemViews.append(itemView)
            content.addArrangedSubview(itemView)
        }

        let itemWidth: CGFloat = 96
        let width = min(CGFloat(items.count) * itemWidth + 32, 720)
        let size = NSSize(width: max(width, 224), height: 126)
        let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main
        let visibleFrame = screen?.visibleFrame ?? .zero
        let origin = NSPoint(
            x: visibleFrame.midX - size.width / 2,
            y: visibleFrame.midY - size.height / 2
        )
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.orderFrontRegardless()
    }

    func updateSelection(_ selectedIndex: Int) {
        for (index, itemView) in itemViews.enumerated() {
            itemView.setSelected(index == selectedIndex)
        }
    }

    func hide() {
        panel.orderOut(nil)
    }

    private func makeItemView(_ item: Item, index: Int, selected: Bool) -> AllowedAppSwitcherItemView {
        let box = AllowedAppSwitcherItemView(index: index, onHover: onHover)
        box.setSelected(selected)

        let image = NSImageView(image: item.icon)
        image.imageScaling = .scaleProportionallyUpOrDown
        image.translatesAutoresizingMaskIntoConstraints = false
        let label = NSTextField(labelWithString: item.name)
        label.textColor = .white
        label.font = .systemFont(ofSize: 11, weight: selected ? .semibold : .regular)
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(image)
        box.addSubview(label)

        NSLayoutConstraint.activate([
            box.widthAnchor.constraint(equalToConstant: 84),
            box.heightAnchor.constraint(equalToConstant: 94),
            image.widthAnchor.constraint(equalToConstant: 52),
            image.heightAnchor.constraint(equalToConstant: 52),
            image.centerXAnchor.constraint(equalTo: box.centerXAnchor),
            image.topAnchor.constraint(equalTo: box.topAnchor, constant: 10),
            label.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 5),
            label.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -5),
            label.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -9)
        ])
        return box
    }
}

private final class AllowedAppSwitcherItemView: NSView {
    private let index: Int
    private let onHover: (Int) -> Void
    private var trackingAreaReference: NSTrackingArea?

    init(index: Int, onHover: @escaping (Int) -> Void) {
        self.index = index
        self.onHover = onHover
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 12
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaReference {
            removeTrackingArea(trackingAreaReference)
        }
        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        trackingAreaReference = trackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        onHover(index)
    }

    func setSelected(_ selected: Bool) {
        layer?.backgroundColor = selected
            ? NSColor(calibratedRed: 0.22, green: 0.40, blue: 0.68, alpha: 0.42).cgColor
            : NSColor.clear.cgColor
        layer?.borderWidth = selected ? 1.5 : 0
        layer?.borderColor = NSColor(calibratedRed: 0.46, green: 0.66, blue: 1, alpha: 0.9).cgColor

        subviews.compactMap { $0 as? NSTextField }.forEach {
            $0.font = .systemFont(ofSize: 11, weight: selected ? .semibold : .regular)
        }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
