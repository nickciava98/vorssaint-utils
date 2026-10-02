// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
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
/// into the system « overflow instead, and the system « and » show and hide
/// them: the manager only keeps the divider long enough on whichever display
/// holds the active menu bar.
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
    /// The shown divider's right edge as a distance from the display's right
    /// edge, which macOS keeps when the active menu bar moves to another
    /// display.
    private var shownFromRight: CGFloat?
    private var rehideTimer: Timer?
    private var pendingWork: DispatchWorkItem?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    /// Set while a hide waits for the system overflow to close.
    private var hidesWhenOverflowCloses = false
    private let osMajor = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "vorssaint",
                                    category: "menubar-manager")

    private init() {}

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
        shownFromRight = nil
        hidesWhenOverflowCloses = false
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
        guard let window = divider?.button?.window else { return }
        observers += [
            (local, local.addObserver(forName: NSWindow.didChangeScreenNotification,
                                      object: window, queue: .main) { [weak self] _ in self?.followActiveMenuBar() }),
            (local, local.addObserver(forName: NSWindow.didMoveNotification,
                                      object: window, queue: .main) { [weak self] _ in self?.hideIfOverflowClosed() }),
        ]
    }

    // MARK: - Hiding and revealing

    @objc private func toggleClicked() {
        if isHidden {
            show()
        } else {
            hide()
        }
    }

    func show() {
        guard let divider else { return }
        pendingWork?.cancel()
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
            shownFromRight = window.screen.map { $0.frame.maxX - window.frame.maxX }
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
            Self.log.info("hide waits: the system overflow holds the divider at \(shownMaxX, privacy: .public)")
            hidesWhenOverflowCloses = true
            return
        }
        hidesWhenOverflowCloses = false
        isHidden = true
        applyHiddenAppearance()
        applyHiddenLength(shownMaxX: shownMaxX, screen: screen)
    }

    private func applyHiddenLength(shownMaxX: CGFloat, screen: NSScreen?) {
        guard let divider else { return }
        let length = MenuBarManagerSupport.hiddenLength(
            osMajor: osMajor, shownMaxX: shownMaxX, screenFrame: screen?.frame ?? .zero,
            cameraMaxX: screen?.auxiliaryTopRightArea?.minX,
            chrome: MenuBarManagerSupport.windowChrome)
        Self.log.info("hiding with length \(length, privacy: .public) from \(shownMaxX, privacy: .public) on \(screen?.localizedName ?? "-", privacy: .public)")
        setLength(divider, length)
        if MenuBarManagerSupport.usesOverflowMenu(osMajor: osMajor) {
            // The frame settles once macOS has laid the hidden items out.
            schedule(after: 0.5) { [weak self] in
                guard let self, !self.undoHideIntoSystemOverflow() else { return }
                self.shortenClampedDivider(length: length, triesLeft: 3)
            }
        }
    }

    /// The active menu bar moved to another display, taking the items with
    /// it. That display has its own room, so the length is worked out again
    /// from the same distance to its right edge.
    private func followActiveMenuBar() {
        guard isHidden, let screen = divider?.button?.window?.screen, let shownFromRight else { return }
        let shownMaxX = screen.frame.maxX - shownFromRight
        self.shownMaxX = shownMaxX
        applyHiddenLength(shownMaxX: shownMaxX, screen: screen)
    }

    /// The divider moves back right of the camera when the system overflow
    /// closes, which is when a waiting hide can run.
    private func hideIfOverflowClosed() {
        guard hidesWhenOverflowCloses, !isHidden, let window = divider?.button?.window,
              let cameraMaxX = window.screen?.auxiliaryTopRightArea?.minX, window.frame.maxX >= cameraMaxX
        else { return }
        // A layout pass later the shown edge has settled.
        schedule(after: 0.3) { [weak self] in self?.hide() }
    }

    /// While the system « has its own overflow open, macOS 27 lays the hidden
    /// items out left of the camera, after the app's menus, and the divider
    /// follows them there instead of hiding anything. Its left edge then
    /// lands left of the camera, so the hide is undone and waits for the
    /// overflow to close.
    private func undoHideIntoSystemOverflow() -> Bool {
        guard isHidden, let divider, let window = divider.button?.window,
              MenuBarManagerSupport.wasCarriedPastCamera(frameMinX: window.frame.minX,
                                                         cameraMinX: window.screen?.auxiliaryTopLeftArea?.maxX)
        else { return false }
        Self.log.info("hide undone: the divider was carried to \(window.frame.minX, privacy: .public) by the system overflow")
        show()
        cancelRehide()
        hidesWhenOverflowCloses = true
        return true
    }

    /// macOS 27 drops a divider that reaches past its floor, which would put
    /// every hidden item back. A clamped frame shows it went too far, but
    /// not where the floor is: measured on a notched and on a Sidecar
    /// display, the frame stopped near its shown edge. So the divider is
    /// halved and checked again.
    private func shortenClampedDivider(length: CGFloat, triesLeft: Int) {
        guard isHidden, triesLeft > 0, let divider, let window = divider.button?.window, let shownMaxX,
              MenuBarManagerSupport.clampedFloor(frame: window.frame, shownMaxX: shownMaxX) != nil
        else { return }
        let shorter = max(MenuBarManagerSupport.materializationLength, (length / 2).rounded(.down))
        Self.log.info("divider clamped; length \(length, privacy: .public) -> \(shorter, privacy: .public)")
        setLength(divider, shorter)
        schedule(after: 0.5) { [weak self] in self?.shortenClampedDivider(length: shorter, triesLeft: triesLeft - 1) }
    }

    /// A new display arrangement moves the divider's anchor, so it is shown
    /// long enough to measure again and then hidden with a fresh length.
    private func relayoutIfHidden() {
        guard isHidden, let divider else { return }
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
