// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import ApplicationServices
import os

/// Hides the menu bar items the user places left of a divider.
///
/// A thin divider marks where hidden items start. The user decides what is
/// hidden by Command-dragging items across it, as macOS allows for any status
/// item; the manager never moves another app's item, never captures the
/// screen and needs no permission.
///
/// Up to macOS 26 the hidden divider pushes the items past the left edge of
/// the display, and a chevron of our own reveals them. On macOS 27 they move
/// into the system « overflow instead. That menu draws them over the
/// frontmost app's menus, so a click on « reveals them in place: the
/// overflow empties and closes, and the items sit beside the others. The
/// system chevron is then the only control, with no second one of ours.
final class MenuBarManagerService: ObservableObject {
    static let shared = MenuBarManagerService()

    @Published private(set) var isHidden = false
    /// True while hiding is refused because the app's own icon sits left of
    /// the divider and would disappear with the other items.
    @Published private(set) var ownIconBlocksHiding = false
    /// True while hiding is refused because our arrow sits left of the
    /// divider, where nothing would be left to bring the items back.
    @Published private(set) var arrowBlocksHiding = false

    /// The main icon's window frame, provided by the app delegate so hiding
    /// can refuse to take the way back into the app with it.
    var mainItemFrame: () -> NSRect? = { nil }

    private var divider: NSStatusItem?
    private var toggle: NSStatusItem?
    private var shownMaxX: CGFloat?
    private var observedFloor: CGFloat?
    private var rehideTimer: Timer?
    private var pendingWork: DispatchWorkItem?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var overflowClickMonitor: Any?
    private let overflowClickTap = OverflowChevronTap()
    private var overflowClickTapActive = false
    private var chevronCenterFromRight: CGFloat?
    /// Set while a hide is retried after closing the system overflow, so a
    /// second failure gives up instead of clicking again.
    private var closedSystemOverflow = false
    /// The reveal happens on mouse down, which puts the divider under the
    /// pointer; the release of that same click must not hide everything again.
    private var ignoreDividerClicksUntil = Date.distantPast
    private let osMajor = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "vorssaint",
                                    category: "menubar-manager")

    private init() {
        // Set once: the pointer thread reads it for as long as the app runs.
        overflowClickTap.onClick = { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.isHidden else { return }
                self.ignoreDividerClicksUntil = Date().addingTimeInterval(MenuBarManagerSupport.revealClickGrace)
                self.show()
            }
        }
    }

    var isActive: Bool {
        AppFeature.menuBarManager.isAvailable
            && UserDefaults.standard.bool(forKey: DefaultsKey.menuBarManagerEnabled)
    }

    func syncWithPreferences() {
        if isActive {
            start()
        } else {
            stop()
        }
    }

    // MARK: - Lifecycle

    private func start() {
        guard divider == nil else { return }
        seedPlacementOnce()
        // A new item takes the spot left of the others, so the arrow comes
        // first and an unseeded divider still lands on its left.
        if !MenuBarManagerSupport.usesOverflowMenu(osMajor: osMajor) {
            toggle = makeItem(autosaveName: MenuBarManagerSupport.toggleAutosaveName,
                              action: #selector(toggleClicked))
        }
        divider = makeItem(autosaveName: MenuBarManagerSupport.dividerAutosaveName,
                           action: #selector(toggleClicked))
        applyShownAppearance()
        observe()
        // The items need a layout pass before their frames can be read.
        schedule(after: 0.6) { [weak self] in self?.hide() }
    }

    private func stop() {
        pendingWork?.cancel()
        pendingWork = nil
        cancelRehide()
        removeOverflowClickMonitor()
        overflowClickTap.tearDown()
        for (center, token) in observers {
            center.removeObserver(token)
        }
        observers = []
        for item in [divider, toggle].compactMap({ $0 }) {
            removeKeepingPosition(item)
        }
        divider = nil
        toggle = nil
        shownMaxX = nil
        observedFloor = nil
        isHidden = false
        ownIconBlocksHiding = false
        arrowBlocksHiding = false
    }

    private func makeItem(autosaveName: String, action: Selector) -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(withLength: MenuBarManagerSupport.materializationLength)
        item.autosaveName = autosaveName
        // Reordering stays possible; dragging our items off the bar does not.
        item.behavior = []
        item.isVisible = true
        item.length = NSStatusItem.variableLength
        if let button = item.button {
            button.target = self
            button.action = action
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.imagePosition = .imageOnly
        }
        return item
    }

    /// Removing a status item forgets its saved position, so the value is put
    /// back afterwards and the item returns to the same spot next time.
    private func removeKeepingPosition(_ item: NSStatusItem) {
        let key = item.autosaveName.map { "NSStatusItem Preferred Position \($0)" }
        let saved = key.flatMap { UserDefaults.standard.object(forKey: $0) }
        NSStatusBar.system.removeStatusItem(item)
        if let key, let saved {
            UserDefaults.standard.set(saved, forKey: key)
        }
    }

    /// Places the chevron and then the divider just left of the main icon the
    /// first time the feature runs. Later launches keep wherever the user
    /// dragged them.
    private func seedPlacementOnce() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: DefaultsKey.menuBarManagerPlacementSeeded) else { return }
        // Without the main icon in the bar there is nothing to seed from, so
        // the next start tries again.
        guard let anchor = mainItemFrame(),
              let screen = NSScreen.screens.first(where: { $0.frame.intersects(anchor) }),
              let togglePosition = MenuBarManagerSupport.seedPosition(
                leftOf: anchor, screenFrame: screen.frame, gap: 2)
        else { return }
        let usesToggle = !MenuBarManagerSupport.usesOverflowMenu(osMajor: osMajor)
        if usesToggle {
            defaults.set(togglePosition,
                         forKey: "NSStatusItem Preferred Position \(MenuBarManagerSupport.toggleAutosaveName)")
        }
        defaults.set(togglePosition + (usesToggle ? 30 : 0),
                     forKey: "NSStatusItem Preferred Position \(MenuBarManagerSupport.dividerAutosaveName)")
        defaults.set(true, forKey: DefaultsKey.menuBarManagerPlacementSeeded)
    }

    private func observe() {
        let workspace = NSWorkspace.shared.notificationCenter
        let local = NotificationCenter.default
        let relayout: (Notification) -> Void = { [weak self] _ in self?.relayoutIfHidden() }
        observers = [
            (local, local.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                      object: nil, queue: .main, using: relayout)),
            (workspace, workspace.addObserver(forName: NSWorkspace.didWakeNotification,
                                              object: nil, queue: .main, using: relayout)),
        ]
    }

    // MARK: - Hiding and revealing

    @objc private func toggleClicked() {
        guard Date() >= ignoreDividerClicksUntil else { return }
        if isHidden {
            show()
        } else {
            hide()
        }
    }

    func show() {
        guard let divider else { return }
        pendingWork?.cancel()
        removeOverflowClickMonitor()
        isHidden = false
        guard toggle == nil else {
            setLength(divider, NSStatusItem.variableLength)
            applyShownAppearance()
            scheduleRehide()
            return
        }
        // macOS 27 slides the shrinking divider into place, and an image set
        // now would ride its left edge across the bar. A fixed width keeps
        // the layout from moving again, and the » appears once it has settled.
        setLength(divider, MenuBarManagerSupport.shownDividerLength)
        schedule(after: MenuBarManagerSupport.revealSettleDelay) { [weak self] in
            self?.applyShownAppearance()
        }
        scheduleRehide()
    }

    func hide() {
        guard let divider, let window = divider.button?.window else { return }
        pendingWork?.cancel()
        cancelRehide()
        if !isHidden {
            shownMaxX = window.frame.maxX
        }
        let strings = FeatureStrings.menuBarManager(L10n.shared.language)
        ownIconBlocksHiding = MenuBarManagerSupport.wouldHide(mainItemFrame(), dividerMinX: window.frame.minX)
        arrowBlocksHiding = MenuBarManagerSupport.wouldHide(toggle?.button?.window?.frame,
                                                            dividerMinX: window.frame.minX)
        if ownIconBlocksHiding || arrowBlocksHiding {
            Self.log.info("hide refused: \(self.ownIconBlocksHiding ? "the main icon" : "the arrow", privacy: .public) is left of the divider")
            // A click that does nothing reads as a broken button, so a click
            // of the user's own says why; the automatic hide stays quiet.
            if NSApp.currentEvent?.type == .leftMouseUp || NSApp.currentEvent?.type == .rightMouseUp {
                explainRefusal(from: divider,
                               text: ownIconBlocksHiding ? strings.ownIconWarning : strings.arrowWarning)
            }
            return
        }
        guard let shownMaxX else { return }
        let screen = window.screen ?? NSScreen.main
        // Only the open system overflow puts the shown divider left of the
        // camera; a divider grown from there hides nothing.
        if MenuBarManagerSupport.usesOverflowMenu(osMajor: osMajor),
           let cameraMaxX = screen?.auxiliaryTopRightArea?.minX, shownMaxX < cameraMaxX {
            Self.log.info("hide skipped: the system overflow holds the divider at \(shownMaxX, privacy: .public)")
            return
        }
        let length = MenuBarManagerSupport.hiddenLength(
            osMajor: osMajor, shownMaxX: shownMaxX, screenFrame: screen?.frame ?? .zero,
            cameraMaxX: screen?.auxiliaryTopRightArea?.minX,
            chrome: MenuBarManagerSupport.windowChrome, observedFloor: observedFloor)
        Self.log.info("hiding with length \(length, privacy: .public) from \(shownMaxX, privacy: .public)")
        isHidden = true
        applyHiddenAppearance()
        setLength(divider, length)
        if MenuBarManagerSupport.usesOverflowMenu(osMajor: osMajor) {
            // The « appears once macOS has laid the hidden items out.
            schedule(after: 0.5) { [weak self] in
                guard let self, !self.undoHideIntoSystemOverflow(length: length) else { return }
                self.correctClampedDivider(length: length)
                self.installOverflowClickMonitor()
            }
        }
    }

    /// Watches for a click on the system « while items are hidden.
    ///
    /// A tap claims the click before macOS sees it, so the overflow menu
    /// never opens over the frontmost app's menus. A click it claims is lost
    /// to whatever is below, so it asks Accessibility what the click landed
    /// on and claims only the « itself, wherever it has moved and whether or
    /// not a menu bar is showing. Without Accessibility a global monitor
    /// still reveals the items, but only after the overflow has flashed
    /// open. Either one exists only while items are hidden.
    private func installOverflowClickMonitor() {
        removeOverflowClickMonitor()
        guard isHidden else { return }
        let strips = MenuBarManagerSupport.menuBarStrips(
            screens: NSScreen.screens.map {
                ($0.frame, max(NSStatusBar.system.thickness, $0.safeAreaInsets.top))
            },
            mainMaxY: NSScreen.screens.first?.frame.maxY ?? 0)
        if let agent = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.MenuBarAgent").first {
            overflowClickTapActive = overflowClickTap.activate(strips: strips, agentPID: agent.processIdentifier)
            if overflowClickTapActive { return }
        }
        guard let chevronCenterFromRight = locateOverflowChevron() else { return }
        self.chevronCenterFromRight = chevronCenterFromRight
        // A global event has no window, so its location is already in screen
        // coordinates, and it is where the click landed, not where the
        // pointer has moved since.
        overflowClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            self?.revealIfOverflowChevronClicked(at: event.locationInWindow)
        }
    }

    private func removeOverflowClickMonitor() {
        if let monitor = overflowClickMonitor {
            NSEvent.removeMonitor(monitor)
        }
        overflowClickMonitor = nil
        if overflowClickTapActive {
            overflowClickTap.deactivate()
            overflowClickTapActive = false
        }
    }

    /// The « as a distance of its center from the right edge of the menu
    /// bar. Accessibility reports it as the one button among MenuBarAgent's
    /// items; without an answer, it is expected where the divider ended.
    private func locateOverflowChevron() -> CGFloat? {
        if let frame = overflowButtonFrame(),
           let screen = NSScreen.screens.first(where: { frame.midX >= $0.frame.minX && frame.midX < $0.frame.maxX }) {
            return screen.frame.maxX - frame.midX
        }
        guard let shownMaxX, let dividerScreen = divider?.button?.window?.screen else { return nil }
        return MenuBarManagerSupport.estimatedChevronCenterFromRight(shownMaxX: shownMaxX,
                                                                     dividerScreen: dividerScreen.frame)
    }

    /// The system chevron's frame in top-left coordinates, as Accessibility
    /// reports it.
    private func overflowButtonFrame() -> CGRect? {
        guard AXIsProcessTrusted(),
              let agent = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.MenuBarAgent").first
        else { return nil }
        let element = AXUIElementCreateApplication(agent.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.1)
        guard let bar = Self.axValue(element, "AXExtrasMenuBar"),
              CFGetTypeID(bar) == AXUIElementGetTypeID(),
              let items = Self.axValue(unsafeBitCast(bar, to: AXUIElement.self), kAXChildrenAttribute) as? [AXUIElement]
        else { return nil }
        return items.lazy
            .filter { (Self.axValue($0, kAXRoleAttribute) as? String) == kAXButtonRole }
            .compactMap(Self.axFrame)
            .first
    }

    private static func axValue(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success ? value : nil
    }

    private static func axFrame(_ element: AXUIElement) -> CGRect? {
        guard let positionValue = axValue(element, kAXPositionAttribute),
              let sizeValue = axValue(element, kAXSizeAttribute),
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID()
        else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(unsafeBitCast(positionValue, to: AXValue.self), .cgPoint, &position)
        AXValueGetValue(unsafeBitCast(sizeValue, to: AXValue.self), .cgSize, &size)
        return CGRect(origin: position, size: size)
    }

    private func revealIfOverflowChevronClicked(at point: NSPoint) {
        guard isHidden, let chevronCenterFromRight,
              let clickScreen = NSScreen.screens.first(where: { $0.frame.contains(point) }),
              MenuBarManagerSupport.isOverflowChevronClick(
                point, clickScreen: clickScreen.frame,
                chevronCenterFromRight: chevronCenterFromRight,
                barHeight: NSStatusBar.system.thickness)
        else { return }
        ignoreDividerClicksUntil = Date().addingTimeInterval(MenuBarManagerSupport.revealClickGrace)
        show()
    }

    /// While the system « has its own overflow open, macOS 27 lays the hidden
    /// items out left of the camera, after the app's menus, and the divider
    /// follows them there instead of hiding anything. Its left edge then
    /// lands far left of where its length should have put it, so the hide
    /// is undone. With Accessibility the system overflow is closed with a
    /// click on its » and the hide tried once more.
    private func undoHideIntoSystemOverflow(length: CGFloat) -> Bool {
        guard isHidden, let divider, let window = divider.button?.window, let shownMaxX,
              MenuBarManagerSupport.wasCarriedPastTarget(frameMinX: window.frame.minX, shownMaxX: shownMaxX,
                                                         length: length, chrome: MenuBarManagerSupport.windowChrome)
        else {
            closedSystemOverflow = false
            return false
        }
        Self.log.info("hide undone: the divider was carried to \(window.frame.minX, privacy: .public) by the system overflow")
        show()
        cancelRehide()
        guard !closedSystemOverflow, let button = overflowButtonFrame() else { return true }
        closedSystemOverflow = true
        let point = CGPoint(x: button.midX, y: button.midY)
        let source = CGEventSource(stateID: .hidSystemState)
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
            CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?
                .post(tap: .cghidEventTap)
        }
        schedule(after: 0.6) { [weak self] in self?.hide() }
        return true
    }

    /// macOS 27 drops a divider that reaches past its floor, which would put
    /// every hidden item back. A clamped frame reports that floor, so the
    /// divider is shortened to stop just short of it.
    private func correctClampedDivider(length: CGFloat) {
        guard isHidden, let divider, let window = divider.button?.window, let shownMaxX,
              let floor = MenuBarManagerSupport.clampedFloor(frame: window.frame, shownMaxX: shownMaxX)
        else { return }
        observedFloor = floor
        let chrome = max(0, window.frame.width - length)
        let corrected = MenuBarManagerSupport.hiddenLength(
            osMajor: osMajor, shownMaxX: shownMaxX, screenFrame: window.screen?.frame ?? .zero,
            cameraMaxX: window.screen?.auxiliaryTopRightArea?.minX,
            chrome: chrome, observedFloor: floor)
        Self.log.info("divider clamped at \(floor, privacy: .public); length \(length, privacy: .public) -> \(corrected, privacy: .public)")
        setLength(divider, corrected)
        // The shorter divider moves the «, so it is found again once settled.
        schedule(after: 0.4) { [weak self] in self?.installOverflowClickMonitor() }
    }

    /// A new display arrangement moves the divider's anchor, so it is shown
    /// long enough to measure again and then hidden with a fresh length.
    private func relayoutIfHidden() {
        guard isHidden, let divider else { return }
        removeOverflowClickMonitor()
        observedFloor = nil
        isHidden = false
        setLength(divider, NSStatusItem.variableLength)
        applyShownAppearance()
        schedule(after: 0.6) { [weak self] in self?.hide() }
    }

    private func scheduleRehide() {
        cancelRehide()
        let seconds = MenuBarManagerSupport.sanitizedRehideSeconds(
            UserDefaults.standard.integer(forKey: DefaultsKey.menuBarManagerRehideSeconds))
        guard seconds > 0 else { return }
        startRehideTimer(after: TimeInterval(seconds))
    }

    private func startRehideTimer(after interval: TimeInterval) {
        rehideTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            guard let self, !self.isHidden else { return }
            let barHeight = NSStatusBar.system.thickness
            if MenuBarManagerSupport.pointerIsOnMenuBar(NSEvent.mouseLocation,
                                                        screenFrames: NSScreen.screens.map(\.frame),
                                                        barHeight: barHeight) {
                self.startRehideTimer(after: MenuBarManagerSupport.rehidePostponeSeconds)
            } else {
                self.hide()
            }
        }
    }

    private func cancelRehide() {
        rehideTimer?.invalidate()
        rehideTimer = nil
    }

    private func schedule(after delay: TimeInterval, _ work: @escaping () -> Void) {
        pendingWork?.cancel()
        let item = DispatchWorkItem(block: work)
        pendingWork = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    /// macOS 26 keeps memory for every status item write until the app
    /// quits, so unchanged values are never written again.
    private func setLength(_ item: NSStatusItem, _ length: CGFloat) {
        guard item.length != length else { return }
        // Items appear and disappear at once rather than sliding or fading.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            item.length = length
            CATransaction.commit()
        }
    }

    /// A small note under the divider, gone at the next click anywhere.
    private func explainRefusal(from item: NSStatusItem, text: String) {
        guard let button = item.button else { return }
        let label = NSTextField(wrappingLabelWithString: text)
        label.preferredMaxLayoutWidth = 260
        label.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView()
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -10),
            label.widthAnchor.constraint(equalToConstant: 260),
        ])
        let controller = NSViewController()
        controller.view = container
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = controller
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    // MARK: - Appearance

    private func applyShownAppearance() {
        let strings = FeatureStrings.menuBarManager(L10n.shared.language)
        // With no chevron of ours, the divider turns into the » that hides
        // the items, the counterpart of the system « that revealed them.
        if toggle == nil {
            setImage(divider, symbol: "chevron.right.2", description: strings.hideTooltip,
                     offset: CGSize(width: MenuBarManagerSupport.overflowChevronShift,
                                    height: divider?.button?.window?.screen?.auxiliaryTopRightArea == nil
                                        ? MenuBarManagerSupport.overflowChevronDrop
                                        : MenuBarManagerSupport.overflowChevronDropBesideCamera))
            divider?.button?.toolTip = strings.hideTooltip
        } else {
            setImage(divider, symbol: "poweron", description: strings.dividerTooltip)
            divider?.button?.toolTip = strings.dividerTooltip
        }
        setImage(toggle, symbol: "chevron.compact.right", description: strings.hideTooltip)
        toggle?.button?.toolTip = strings.hideTooltip
    }

    private func applyHiddenAppearance() {
        let strings = FeatureStrings.menuBarManager(L10n.shared.language)
        divider?.button?.image = nil
        divider?.button?.toolTip = nil
        setImage(toggle, symbol: "chevron.compact.left", description: strings.showTooltip)
        toggle?.button?.toolTip = strings.showTooltip
    }

    /// `offset` moves the glyph right and down from where the button would
    /// center it; a negative height moves it up.
    private func setImage(_ item: NSStatusItem?, symbol: String, description: String, offset: CGSize = .zero) {
        guard let button = item?.button,
              let symbolImage = NSImage(systemSymbolName: symbol, accessibilityDescription: description)
        else { return }
        guard offset != .zero else {
            symbolImage.isTemplate = true
            button.image = symbolImage
            return
        }
        // The button centers its image, so empty room on one side moves the
        // glyph toward the other by half that room.
        let size = NSSize(width: symbolImage.size.width + abs(offset.width) * 2,
                          height: symbolImage.size.height + abs(offset.height) * 2)
        let image = NSImage(size: size, flipped: false) { _ in
            let origin = CGPoint(x: max(0, offset.width) * 2, y: max(0, -offset.height) * 2)
            symbolImage.draw(in: NSRect(origin: origin, size: symbolImage.size))
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = description
        button.image = image
    }
}

/// Claims clicks on the system « before the window server delivers them.
///
/// The tap is served by the pointer thread, which answers at once whatever
/// the main thread is doing. It is made once and lives as long as the
/// service: an event already on its way when the items are revealed still
/// finds this object, so the tap is only ever switched off, never freed.
private final class OverflowChevronTap {
    /// Assigned once, before the tap first runs.
    var onClick: (() -> Void)?
    private var port: CFMachPort?
    private var source: CFRunLoopSource?
    private let lock = NSLock()
    /// Written on the main thread, read by the callback, both under `lock`.
    private var strips: [CGRect] = []
    private var agentPID: pid_t = 0
    private var isActive = false
    /// The release that ends a claimed press is claimed too, so no app sees
    /// half a click. Under `lock`: switching the tap on clears it, since the
    /// reveal switches the tap off before that release arrives.
    private var claimedPress = false

    /// The system-wide element answers which item is under a point. A short
    /// timeout keeps a slow answer from holding the click.
    private let systemWide: AXUIElement = {
        let element = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(element, 0.05)
        return element
    }()

    /// Starts claiming clicks on the « that MenuBarAgent draws, looked for
    /// only in `strips`. False when the tap cannot exist, which is the case
    /// without Accessibility.
    func activate(strips: [CGRect], agentPID: pid_t) -> Bool {
        guard AXIsProcessTrusted(), let port = port ?? makePort() else { return false }
        lock.lock()
        self.strips = strips
        self.agentPID = agentPID
        isActive = true
        claimedPress = false
        lock.unlock()
        CGEvent.tapEnable(tap: port, enable: true)
        return true
    }

    func deactivate() {
        lock.lock()
        strips = []
        isActive = false
        lock.unlock()
        if let port { CGEvent.tapEnable(tap: port, enable: false) }
    }

    /// Gives the port back when the feature stops. This object stays, so an
    /// event already on the pointer thread still finds it; the next
    /// activation makes a new port.
    func tearDown() {
        deactivate()
        guard let port, let source else { return }
        PointerTapRunLoop.remove(source, invalidating: port)
        self.port = nil
        self.source = nil
    }

    private func makePort() -> CFMachPort? {
        let mask = CGEventMask(1 << CGEventType.leftMouseDown.rawValue)
            | CGEventMask(1 << CGEventType.leftMouseUp.rawValue)
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let tap = Unmanaged<OverflowChevronTap>.fromOpaque(userInfo).takeUnretainedValue()
                return tap.handle(type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return nil }
        self.port = port
        if let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) {
            self.source = source
            PointerTapRunLoop.add(source)
        }
        return port
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        lock.lock()
        let active = isActive
        let onBar = active && strips.contains(where: { $0.contains(event.location) })
        let pid = agentPID
        let claimsRelease = type == .leftMouseUp && claimedPress
        if type == .leftMouseUp { claimedPress = false }
        lock.unlock()
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if active, let port { CGEvent.tapEnable(tap: port, enable: true) }
            return Unmanaged.passUnretained(event)
        case .leftMouseDown:
            // Asked outside the lock: the main thread may be switching the
            // tap off meanwhile.
            guard onBar, isOverflowChevron(at: event.location, agentPID: pid) else {
                return Unmanaged.passUnretained(event)
            }
            lock.lock()
            claimedPress = true
            lock.unlock()
            onClick?()
            return nil
        case .leftMouseUp:
            return claimsRelease ? nil : Unmanaged.passUnretained(event)
        default:
            return Unmanaged.passUnretained(event)
        }
    }

    /// The « is the one button MenuBarAgent puts in the bar; its other items
    /// are groups. Measured on macOS 27 at about half a millisecond a click.
    private func isOverflowChevron(at point: CGPoint, agentPID: pid_t) -> Bool {
        var item: AXUIElement?
        var pid: pid_t = 0
        guard AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &item) == .success,
              let item, AXUIElementGetPid(item, &pid) == .success,
              // Only MenuBarAgent is asked anything more; other apps' items
              // are left alone.
              pid == agentPID
        else { return false }
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(item, kAXRoleAttribute as CFString, &role)
        return (role as? String) == kAXButtonRole
    }
}
