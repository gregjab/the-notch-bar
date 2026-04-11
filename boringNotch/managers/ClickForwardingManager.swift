//
//  ClickForwardingManager.swift
//  boringNotch
//
//  Created for The Notch Bar: Phase 1 - Click Forwarding and Dismissal State
//

import AppKit
import ApplicationServices
import Combine
import os.log

@MainActor
final class ClickForwardingManager: ObservableObject {
    static let shared = ClickForwardingManager()

    /// Whether a dropdown menu is currently active (suppresses panel auto-close)
    @Published private(set) var isDropdownActive: Bool = false

    private let logger = os.Logger(subsystem: Bundle.main.bundleIdentifier!, category: "ClickForwarding")
    private var dismissalTimeoutTask: Task<Void, Never>?
    private var frontmostAppObserver: Any?
    private var axObserver: AXObserver?

    private init() {}

    // MARK: - Public API

    func performClick(on item: HiddenMenuBarItem) {
        logger.info("Clicking \(item.appName) (\(item.id))")

        // Synchronous refresh to verify item still exists
        MenuBarItemDetector.shared.refreshImmediate()

        // If there's already an active dropdown, exit it first
        if isDropdownActive {
            exitDropdownActiveState()
        }

        // Attempt AX press first
        if performAXPress(on: item.element) {
            logger.info("AXPress succeeded for \(item.appName)")
            enterDropdownActiveState(for: item)
        } else {
            logger.warning("AXPress failed for \(item.appName), falling back to CGEvent")
            let clickPoint = CGPoint(
                x: item.frame.midX,
                y: item.frame.midY
            )
            performCGEventClick(at: clickPoint)
            enterDropdownActiveState(for: item)
        }
    }

    // MARK: - Internal

    private func performAXPress(on element: AXUIElement) -> Bool {
        let result = AXUIElementPerformAction(element, kAXPressAction as CFString)
        return result == .success
    }

    private func performCGEventClick(at point: CGPoint) {
        // Convert from AppKit coordinates (bottom-left origin of primary screen)
        // to Quartz/CG coordinates (top-left origin of primary screen)
        guard let mainScreenHeight = NSScreen.screens.first?.frame.height else {
            logger.error("No screens available for coordinate conversion")
            return
        }

        let cgPoint = CGPoint(
            x: point.x,
            y: mainScreenHeight - point.y
        )

        logger.debug("CGEvent click at CG coords: \(cgPoint.x), \(cgPoint.y) (AppKit: \(point.x), \(point.y))")

        let mouseDown = CGEvent(
            mouseEventSource: nil,
            mouseType: .leftMouseDown,
            mouseCursorPosition: cgPoint,
            mouseButton: .left
        )
        let mouseUp = CGEvent(
            mouseEventSource: nil,
            mouseType: .leftMouseUp,
            mouseCursorPosition: cgPoint,
            mouseButton: .left
        )

        mouseDown?.post(tap: .cghidEventTap)
        // Small delay between down and up for reliable handling.
        // Note: This blocks MainActor for 50ms. Acceptable for a fallback path.
        usleep(50_000)
        mouseUp?.post(tap: .cghidEventTap)

        logger.info("CGEvent click posted at \(cgPoint.x), \(cgPoint.y)")
    }

    private func enterDropdownActiveState(for item: HiddenMenuBarItem) {
        isDropdownActive = true
        logger.info("Entered dropdown-active state for \(item.appName)")

        observeMenuClosed(for: item)
        startDismissalTimeout()

        // Observe frontmost app changes
        let itemPID = item.pid
        frontmostAppObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            // If the newly frontmost app is not the one whose dropdown we opened, dismiss
            if app.processIdentifier != itemPID {
                Task { @MainActor in
                    self?.exitDropdownActiveState()
                }
            }
        }
    }

    func exitDropdownActiveState() {
        guard isDropdownActive else { return }
        isDropdownActive = false
        logger.info("Exited dropdown-active state")

        dismissalTimeoutTask?.cancel()
        dismissalTimeoutTask = nil

        // Remove AX observer
        if let observer = axObserver {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
            axObserver = nil
        }

        // Remove frontmost app observer
        if let observer = frontmostAppObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            frontmostAppObserver = nil
        }
    }

    private func observeMenuClosed(for item: HiddenMenuBarItem) {
        var observer: AXObserver?
        let result = AXObserverCreate(
            item.pid,
            { (observer, element, notification, refcon) in
                // Callback fires on the main run loop
                Task { @MainActor in
                    ClickForwardingManager.shared.exitDropdownActiveState()
                }
            },
            &observer
        )

        guard result == .success, let observer = observer else {
            logger.warning("Failed to create AXObserver for menu closed notification")
            return
        }

        // IMPORTANT: Observe the APPLICATION element, not the menu bar item element.
        // AXMenuClosed fires on the app-level AXUIElement, not on individual menu bar items.
        let appElement = AXUIElementCreateApplication(item.pid)
        AXObserverAddNotification(observer, appElement, "AXMenuClosed" as CFString, nil)
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)

        self.axObserver = observer
    }

    private func startDismissalTimeout() {
        dismissalTimeoutTask?.cancel()
        dismissalTimeoutTask = Task {
            do {
                try await Task.sleep(for: .seconds(10))
            } catch {
                return // Cancelled
            }
            guard !Task.isCancelled else { return }
            logger.debug("Dropdown dismissal timeout fired after 10 seconds")
            exitDropdownActiveState()
        }
    }
}
