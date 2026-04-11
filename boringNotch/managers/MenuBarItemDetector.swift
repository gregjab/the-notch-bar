//
//  MenuBarItemDetector.swift
//  boringNotch
//
//  Created for The Notch Bar: Phase 1 - Hidden Menu Bar Icon Detection
//

import AppKit
import ApplicationServices
import Combine
import Defaults
import os.log

@MainActor
final class MenuBarItemDetector: ObservableObject {
    static let shared = MenuBarItemDetector()

    /// Per-screen hidden items. Key is display UUID string.
    @Published private(set) var hiddenItemsByScreen: [String: [HiddenMenuBarItem]] = [:]

    private let logger = os.Logger(subsystem: Bundle.main.bundleIdentifier!, category: "MenuBarItemDetector")
    private var workspaceObservers: [Any] = []
    private var refreshTask: Task<Void, Never>?
    private var periodicRefreshTask: Task<Void, Never>?

    private init() {}

    deinit {
        // workspaceObservers cleanup happens synchronously in stopObserving
    }

    // MARK: - Public API

    func startObserving() {
        guard workspaceObservers.isEmpty else {
            logger.debug("MenuBarItemDetector already observing, skipping startObserving()")
            return
        }

        logger.info("MenuBarItemDetector starting observation")

        let appLaunchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }

        let appTerminateObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }

        let screenChangeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }

        workspaceObservers = [appLaunchObserver, appTerminateObserver, screenChangeObserver]

        // Initial detection
        refresh()
    }

    func stopObserving() {
        logger.info("MenuBarItemDetector stopping observation")

        for observer in workspaceObservers {
            // Need to determine which center each came from.
            // We stored them as Any, so try both centers.
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            NotificationCenter.default.removeObserver(observer)
        }
        workspaceObservers.removeAll()

        refreshTask?.cancel()
        refreshTask = nil

        stopPeriodicRefresh()

        hiddenItemsByScreen = [:]
    }

    /// Debounced refresh (200ms). Use for bulk triggers (app launch, screen change).
    func refresh() {
        refreshTask?.cancel()
        refreshTask = Task {
            do {
                try await Task.sleep(for: .milliseconds(200))
            } catch {
                return // Cancelled
            }
            guard !Task.isCancelled else { return }
            performEnumerationAndClassification()
        }
    }

    /// Synchronous refresh with no debounce. Use when results are needed immediately (e.g., before click forwarding).
    func refreshImmediate() {
        refreshTask?.cancel()
        refreshTask = nil
        performEnumerationAndClassification()
    }

    /// Start periodic 10-second refresh (called by BoringViewModel.open())
    func startPeriodicRefresh() {
        stopPeriodicRefresh()
        periodicRefreshTask = Task {
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(10))
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                refresh()
            }
        }
    }

    /// Stop periodic refresh (called by BoringViewModel.close())
    func stopPeriodicRefresh() {
        periodicRefreshTask?.cancel()
        periodicRefreshTask = nil
    }

    /// Convenience accessor for items on a specific screen
    func items(forScreen uuid: String) -> [HiddenMenuBarItem] {
        return hiddenItemsByScreen[uuid] ?? []
    }

    // MARK: - Internal

    private func performEnumerationAndClassification() {
        guard AXIsProcessTrusted() else {
            logger.warning("AX permission not granted; MenuBarItemDetector cannot enumerate menu bar items")
            hiddenItemsByScreen = [:]
            return
        }

        let allItems = enumerateAllMenuBarItems()

        var result: [String: [HiddenMenuBarItem]] = [:]
        for screen in NSScreen.screens {
            guard let uuid = screen.displayUUID else { continue }
            let hiddenItems = allItems.filter { classifyItem($0, screen: screen) }
            result[uuid] = hiddenItems
        }

        hiddenItemsByScreen = result
        logger.debug("MenuBarItemDetector found \(allItems.count) total items; \(result.values.map(\.count).reduce(0, +)) hidden across all screens")
    }

    private func enumerateAllMenuBarItems() -> [HiddenMenuBarItem] {
        var items: [HiddenMenuBarItem] = []

        let runningApps = NSWorkspace.shared.runningApplications.filter { $0.isFinishedLaunching }

        for app in runningApps {
            let pid = app.processIdentifier
            let appElement = AXUIElementCreateApplication(pid)

            // Query the extras menu bar (right-side, third-party status items)
            // "AXExtrasMenuBar" is NOT a named constant; use the string literal directly.
            var extrasMenuBarValue: AnyObject?
            let extrasResult = AXUIElementCopyAttributeValue(
                appElement,
                "AXExtrasMenuBar" as CFString,
                &extrasMenuBarValue
            )

            guard extrasResult == .success, let extrasMenuBar = extrasMenuBarValue else {
                // This app does not expose an extras menu bar; skip silently.
                continue
            }

            let extrasMenuBarElement = extrasMenuBar as! AXUIElement

            // Get children of the extras menu bar
            var childrenValue: AnyObject?
            let childrenResult = AXUIElementCopyAttributeValue(
                extrasMenuBarElement,
                "AXChildren" as CFString,
                &childrenValue
            )

            guard childrenResult == .success,
                  let children = childrenValue as? [AXUIElement] else {
                continue
            }

            let bundleID = app.bundleIdentifier
            let appName = app.localizedName ?? bundleID ?? "Unknown"

            for child in children {
                // Extract frame
                var frameValue: AnyObject?
                guard AXUIElementCopyAttributeValue(child, "AXFrame" as CFString, &frameValue) == .success,
                      let frameVal = frameValue else {
                    logger.debug("Could not get frame for menu bar item of \(appName)")
                    continue
                }

                var frame: CGRect = .zero
                guard AXValueGetValue(frameVal as! AXValue, .cgRect, &frame) else {
                    continue
                }

                // Skip items with zero size (stale or invalid)
                guard frame.width > 0, frame.height > 0 else { continue }

                // Extract AXIdentifier (may be nil)
                var idValue: AnyObject?
                let axIdentifier: String?
                if AXUIElementCopyAttributeValue(child, "AXIdentifier" as CFString, &idValue) == .success,
                   let idStr = idValue as? String, !idStr.isEmpty {
                    axIdentifier = idStr
                } else {
                    axIdentifier = nil
                }

                // Extract AXTitle (may be nil)
                var titleValue: AnyObject?
                let title: String?
                if AXUIElementCopyAttributeValue(child, "AXTitle" as CFString, &titleValue) == .success,
                   let titleStr = titleValue as? String, !titleStr.isEmpty {
                    title = titleStr
                } else {
                    title = nil
                }

                // Build dedup key
                let dedupeKey: String
                if let axIdentifier = axIdentifier {
                    dedupeKey = "\(pid):\(bundleID ?? "unknown"):\(axIdentifier)"
                } else if let title = title {
                    dedupeKey = "\(pid):\(bundleID ?? "unknown"):\(title)"
                } else {
                    dedupeKey = "\(pid):\(bundleID ?? "unknown"):\(Int(frame.origin.x))"
                }

                // Attempt icon capture
                let iconImage = captureIconImage(for: child, frame: frame)

                let item = HiddenMenuBarItem(
                    id: dedupeKey,
                    pid: pid,
                    bundleIdentifier: bundleID,
                    appName: appName,
                    axIdentifier: axIdentifier,
                    title: title,
                    frame: frame,
                    element: child,
                    iconImage: iconImage
                )

                items.append(item)
            }
        }

        return items
    }

    private func classifyItem(_ item: HiddenMenuBarItem, screen: NSScreen) -> Bool {
        guard let deadZone = computeNotchDeadZone(for: screen) else {
            return false // No notch on this screen
        }

        let intersection = item.frame.intersection(deadZone)
        guard !intersection.isNull else { return false }

        let itemArea = item.frame.width * item.frame.height
        guard itemArea > 0 else { return false }

        let intersectionArea = intersection.width * intersection.height

        // Hidden if > 50% overlap
        if intersectionArea > itemArea * 0.5 {
            return true
        }

        // Additional check: fully between left and right edges of dead zone
        if item.frame.minX >= deadZone.minX && item.frame.maxX <= deadZone.maxX {
            return true
        }

        return false
    }

    private func computeNotchDeadZone(for screen: NSScreen) -> CGRect? {
        // Only screens with a notch have a dead zone
        guard screen.safeAreaInsets.top > 0 else { return nil }

        // Both auxiliary areas must be present
        guard let topLeftArea = screen.auxiliaryTopLeftArea,
              let topRightArea = screen.auxiliaryTopRightArea else {
            return nil
        }

        // Dead zone spans the notch area at the top of the screen
        // In AppKit coordinates (origin at bottom-left):
        //   top of screen = screen.frame.maxY
        //   dead zone bottom = screen.frame.maxY - safeAreaInsets.top
        let deadZoneLeft = screen.frame.origin.x + topLeftArea.width
        let deadZoneRight = screen.frame.origin.x + screen.frame.width - topRightArea.width
        let deadZoneBottom = screen.frame.maxY - screen.safeAreaInsets.top
        let deadZoneHeight = screen.safeAreaInsets.top

        return CGRect(
            x: deadZoneLeft,
            y: deadZoneBottom,
            width: deadZoneRight - deadZoneLeft,
            height: deadZoneHeight
        )
    }

    private func captureIconImage(for element: AXUIElement, frame: CGRect) -> NSImage? {
        // First attempt: query AXImage attribute
        var imageValue: AnyObject?
        if AXUIElementCopyAttributeValue(element, "AXImage" as CFString, &imageValue) == .success,
           let image = imageValue {
            if let nsImage = image as? NSImage {
                return nsImage
            }
        }

        // Fallback: CGWindowListCreateImage of the item's frame region.
        // Note: CGWindowListCreateImage is deprecated in macOS 14 but still functional.
        // Convert from AppKit coordinates (bottom-left origin) to CG coordinates (top-left origin)
        guard let mainScreen = NSScreen.screens.first else { return nil }
        let mainScreenHeight = mainScreen.frame.height
        let cgRect = CGRect(
            x: frame.origin.x,
            y: mainScreenHeight - frame.origin.y - frame.height,
            width: frame.width,
            height: frame.height
        )

        if let cgImage = CGWindowListCreateImage(
            cgRect,
            .optionOnScreenOnly,
            kCGNullWindowID,
            .bestResolution
        ) {
            return NSImage(cgImage: cgImage, size: frame.size)
        }

        return nil
    }
}
