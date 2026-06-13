//
//  QuickPickerManager.swift
//  ClipVault
//
//  State machine behind the ⇧⌘7 hotkey:
//    tap + release        → open the View All window
//    hold ⌘⇧, tap 7 again → quick picker panel at the cursor; further 7 taps or
//                           ↓/↑ move the selection; releasing ⌘⇧ (or Enter)
//                           pastes the selected item into the previously
//                           frontmost app; Esc or click-outside cancels.
//
//  Requires Accessibility permission (paste synthesis + event monitors).
//  Without it the hotkey degrades to opening the View All window directly.
//

import AppKit
import SwiftUI
import Carbon.HIToolbox

final class QuickPickerManager: NSObject, NSWindowDelegate {
    static let shared = QuickPickerManager()

    /// Wired by AppDelegate to open the View All window.
    var openWindow: (() -> Void)?

    private enum State: String {
        case idle, armed, picking, pendingPaste
    }

    private var state: State = .idle {
        didSet {
            AppLogger.hotkeys.debug("Quick picker state: \(oldValue.rawValue, privacy: .public) → \(self.state.rawValue, privacy: .public)")
        }
    }

    private var targetApp: NSRunningApplication?
    private var panel: QuickPickerPanel?
    private var hostingController: NSHostingController<QuickPickerView>?
    private var viewModel: QuickPickerViewModel?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var pendingItem: ClipItem?
    private var pasteTimeoutWorkItem: DispatchWorkItem?
    private var didPromptForAccessibility = false

    private override init() {
        super.init()
    }

    // MARK: - Hotkey Entry Point

    /// Called on the main queue for every ⇧⌘7 press (HotKeyManager dispatches async).
    func handleHotKeyPress() {
        switch state {
        case .idle:
            beginArmed()
        case .armed:
            showPicker()
        case .picking:
            viewModel?.moveSelection(by: 1)
        case .pendingPaste:
            break
        }
    }

    /// Tears down monitors and panel; safe to call at app termination.
    func teardown() {
        reset()
    }

    // MARK: - State Transitions

    private func beginArmed() {
        guard PasteHelper.shared.checkAccessibilityPermissions() else {
            // Picker can't paste (or reliably monitor events) without Accessibility -
            // degrade to the plain window-open behaviour.
            openWindow?()
            if !didPromptForAccessibility {
                didPromptForAccessibility = true
                PasteHelper.shared.promptForAccessibilityPermissions()
            }
            return
        }

        targetApp = NSWorkspace.shared.frontmostApplication
        installMonitors()
        state = .armed

        // The Carbon callback is async-dispatched: the modifiers may already be up
        // by the time we get here (fast tap). Check synchronously to close the race.
        if modifiersReleased(NSEvent.modifierFlags) {
            finishArmedAsTap()
        }
    }

    private func finishArmedAsTap() {
        reset()
        openWindow?()
    }

    private func showPicker() {
        let items = (try? ClipItemManager.shared.fetchRecentItems(limit: 8)) ?? []

        let vm = QuickPickerViewModel(items: items)
        vm.onRowClicked = { [weak self] index in
            guard let self, self.state == .picking else { return }
            self.viewModel?.selectedIndex = index
            self.confirmSelection()
        }
        viewModel = vm

        let hosting = NSHostingController(rootView: QuickPickerView(viewModel: vm))
        let size = hosting.view.fittingSize
        let newPanel = QuickPickerPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        newPanel.contentViewController = hosting
        newPanel.isOpaque = false
        newPanel.backgroundColor = .clear
        newPanel.level = .statusBar
        newPanel.collectionBehavior = [.canJoinAllSpaces, .transient]
        newPanel.ignoresMouseEvents = false
        newPanel.hasShadow = true
        newPanel.isMovable = false
        newPanel.isReleasedWhenClosed = false
        newPanel.delegate = self

        hostingController = hosting
        panel = newPanel

        positionPanelAtCursor(newPanel)
        state = .picking
        newPanel.makeKeyAndOrderFront(nil)
    }

    private func confirmSelection() {
        guard let vm = viewModel, !vm.items.isEmpty,
              vm.items.indices.contains(vm.selectedIndex) else {
            cancel()
            return
        }

        pendingItem = vm.items[vm.selectedIndex]
        state = .pendingPaste
        panel?.orderOut(nil)

        if NSEvent.modifierFlags.intersection([.command, .shift]).isEmpty {
            performPendingPaste()
        } else {
            // Wait for full ⌘⇧ release before synthesizing ⌘V, otherwise the
            // physically-held ⇧ merges into a ⌘⇧V in the target app.
            let work = DispatchWorkItem { [weak self] in
                AppLogger.hotkeys.debug("Quick picker paste timeout fired; pasting anyway")
                self?.performPendingPaste()
            }
            pasteTimeoutWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
        }
    }

    private func performPendingPaste() {
        pasteTimeoutWorkItem?.cancel()
        pasteTimeoutWorkItem = nil

        guard state == .pendingPaste, let item = pendingItem else {
            reset()
            return
        }

        let target = targetApp
        reset()

        _ = PasteHelper.shared.pasteItem(item, autoPaste: true, targetApp: target)
        NotificationManager.shared.showPastedNotification()
    }

    private func cancel() {
        AppLogger.hotkeys.debug("Quick picker cancelled")
        reset()
    }

    private func reset() {
        pasteTimeoutWorkItem?.cancel()
        pasteTimeoutWorkItem = nil
        pendingItem = nil
        targetApp = nil
        removeMonitors()
        if state != .idle {
            // Set state BEFORE hiding the panel so windowDidResignKey's
            // picking-state cancel guard can't misfire on programmatic hides.
            state = .idle
        }
        panel?.orderOut(nil)
        panel = nil
        hostingController = nil
        viewModel = nil
    }

    // MARK: - Event Monitors

    private func installMonitors() {
        guard globalMonitor == nil, localMonitor == nil else { return }

        // Global monitor: release detection + click-outside while another app is
        // frontmost. (Our own app's events never reach a global monitor.)
        globalMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.flagsChanged, .leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            self?.handleGlobalEvent(event)
        }

        // Local monitor: same signals when ClipVault itself owns key (the picker
        // panel), plus arrow/Enter/Esc navigation.
        localMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.flagsChanged, .keyDown]
        ) { [weak self] event in
            return self?.handleLocalEvent(event) ?? event
        }
    }

    private func removeMonitors() {
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
            self.globalMonitor = nil
        }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
    }

    private func handleGlobalEvent(_ event: NSEvent) {
        switch event.type {
        case .flagsChanged:
            handleFlagsChanged(event.modifierFlags)
        case .leftMouseDown, .rightMouseDown:
            if state == .picking {
                cancel()
            }
        default:
            break
        }
    }

    private func handleLocalEvent(_ event: NSEvent) -> NSEvent? {
        if event.type == .flagsChanged {
            handleFlagsChanged(event.modifierFlags)
            return event
        }

        guard state == .picking else { return event }

        switch Int(event.keyCode) {
        case kVK_DownArrow:
            viewModel?.moveSelection(by: 1)
            return nil
        case kVK_UpArrow:
            viewModel?.moveSelection(by: -1)
            return nil
        case kVK_Return, kVK_ANSI_KeypadEnter:
            confirmSelection()
            return nil
        case kVK_Escape:
            cancel()
            return nil
        case kVK_ANSI_7:
            // Selection movement comes via the Carbon hotkey re-fire; just
            // swallow the raw keypress so it can't leak anywhere.
            return nil
        default:
            return event
        }
    }

    private func handleFlagsChanged(_ flags: NSEvent.ModifierFlags) {
        switch state {
        case .idle:
            break
        case .armed:
            if modifiersReleased(flags) {
                finishArmedAsTap()
            }
        case .picking:
            if modifiersReleased(flags) {
                confirmSelection()
            }
        case .pendingPaste:
            if flags.intersection([.command, .shift]).isEmpty {
                performPendingPaste()
            }
        }
    }

    /// "Released" = either half of the ⌘⇧ chord is up.
    private func modifiersReleased(_ flags: NSEvent.ModifierFlags) -> Bool {
        return !flags.contains(.command) || !flags.contains(.shift)
    }

    // MARK: - Panel Positioning

    private func positionPanelAtCursor(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main

        var topLeft = NSPoint(x: mouse.x + 8, y: mouse.y - 8)
        if let visible = screen?.visibleFrame {
            let size = panel.frame.size
            topLeft.x = min(max(topLeft.x, visible.minX), max(visible.minX, visible.maxX - size.width))
            topLeft.y = min(max(topLeft.y, visible.minY + size.height), visible.maxY)
        }
        panel.setFrameTopLeftPoint(topLeft)
    }

    // MARK: - NSWindowDelegate

    func windowDidResignKey(_ notification: Notification) {
        // Only treat resign-key as click-outside while actively picking;
        // programmatic hides set state first so this can't misfire.
        if state == .picking {
            cancel()
        }
    }
}

// MARK: - QuickPickerPanel

/// Borderless panels refuse key status by default; the picker needs it for
/// arrow/Enter/Esc handling (same pattern as Spotlight-style panels).
final class QuickPickerPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}
