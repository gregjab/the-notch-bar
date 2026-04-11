# Spec: Click Forwarding and Dismissal State

## Overview

ClickForwardingManager handles two responsibilities:

1. **Click forwarding**: When a user clicks a hidden icon in the HiddenIconRow, activate the corresponding native menu bar item to open its dropdown menu.
2. **Dismissal state**: Prevent the notch panel from auto-closing while a native dropdown menu is open, then return to normal close behaviour once the dropdown dismisses.

## ClickForwardingManager

### File: `boringNotch/managers/ClickForwardingManager.swift` (new)

```swift
import AppKit
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

    private init() { ... }

    // Public API
    func performClick(on item: HiddenMenuBarItem) { ... }

    // Internal
    private func performAXPress(on element: AXUIElement) -> Bool { ... }
    private func performCGEventClick(at point: CGPoint) { ... }
    private func enterDropdownActiveState(for item: HiddenMenuBarItem) { ... }
    private func exitDropdownActiveState() { ... }
    private func startDismissalTimeout() { ... }
    private func observeMenuClosed(for item: HiddenMenuBarItem) { ... }
}
```

## Click Forwarding

### `performClick(on:)`

This is the entry point called from HiddenIconRow when a user taps an icon.

**Sequence:**

1. Log the attempt: `logger.info("Clicking \(item.appName) (\(item.id))")`
2. First, refresh the item to ensure the AXUIElement is still valid:
   - Call `MenuBarItemDetector.shared.refreshImmediate()` (synchronous, no debounce, runs enumeration inline on MainActor)
   - Look up the item by `id` in the refreshed list
   - If not found (app quit), log warning and return. The UI will update on next publish cycle.
3. Attempt AX press: `performAXPress(on: item.element)`
4. If AX press succeeds:
   - Log success: `logger.info("AXPress succeeded for \(item.appName)")`
   - Enter dropdown-active state: `enterDropdownActiveState(for: item)`
5. If AX press fails:
   - Log the failure: `logger.warning("AXPress failed for \(item.appName), falling back to CGEvent")`
   - Calculate click point: midpoint of `item.frame`
   - `performCGEventClick(at: clickPoint)`
   - Enter dropdown-active state: `enterDropdownActiveState(for: item)`

### `performAXPress(on:)` -> Bool

```swift
private func performAXPress(on element: AXUIElement) -> Bool {
    let result = AXUIElementPerformAction(element, kAXPressAction as CFString)
    return result == .success
}
```

This is the primary activation path. It tells the AX system to press the menu bar item, which causes the owning app to open its dropdown menu natively.

### `performCGEventClick(at:)` 

Fallback for items where AXPress does not work (some apps use custom NSView-based status items that do not respond to AXPress).

```swift
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

    // Note: CGEvent coordinates are in global display coordinates with top-left origin
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
    // Small delay between down and up for reliable handling
    usleep(50_000) // 50ms
    mouseUp?.post(tap: .cghidEventTap)

    logger.info("CGEvent click posted at \(cgPoint)")
}
```

**Coordinate system note**: AXFrame reports in AppKit screen coordinates (origin at bottom-left of main display). CGEvent expects Quartz coordinates (origin at top-left of main display). The conversion is:

```
cgY = mainScreenHeight - appKitY
```

For multi-display setups, the conversion must account for the screen's position in the global coordinate space.

**Retina note**: AXFrame already reports logical points, not physical pixels. No Retina scaling is needed.

## Dismissal State Model

### States

```
[idle] ---(icon clicked)---> [dropdown-active] ---(menu closed)---> [idle]
```

- **idle**: Normal state. Panel auto-closes on hover-leave as usual.
- **dropdown-active**: A native dropdown menu is open. Panel must NOT auto-close.

### `enterDropdownActiveState(for:)`

1. Set `isDropdownActive = true`
2. Start an AXObserver for `"AXMenuClosed" as CFString` on the item's element: `observeMenuClosed(for: item)`
3. Start dismissal timeout: `startDismissalTimeout()` (10 seconds)
4. Observe frontmost app changes: if the frontmost app changes to something other than the item's owning app, exit dropdown state

### `exitDropdownActiveState()`

1. Set `isDropdownActive = false`
2. Cancel the timeout task
3. Remove the AX observer
4. Remove the frontmost app observer

### Transition Triggers (dropdown-active -> idle)

Any ONE of these triggers the transition:

| Trigger | Mechanism |
|---------|-----------|
| `"AXMenuClosed" as CFString` | AXObserver callback on the menu bar item's element |
| 10-second timeout | `Task.sleep` in `startDismissalTimeout()` |
| Frontmost app changed | `NSWorkspace.didActivateApplicationNotification` where new app PID differs from item PID |

### AXObserver for Menu Closed

```swift
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
```

### Frontmost App Observer

```swift
NSWorkspace.shared.notificationCenter.addObserver(
    forName: NSWorkspace.didActivateApplicationNotification,
    object: nil,
    queue: .main
) { [weak self] notification in
    guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
    // If the newly frontmost app is not the one whose dropdown we opened, dismiss
    if app.processIdentifier != item.pid {
        Task { @MainActor in
            self?.exitDropdownActiveState()
        }
    }
}
```

## Integration with Panel Auto-Close

The existing auto-close logic lives in two places:

### 1. ContentView.swift: handleHover() (line 511-558)

The hover-leave branch (line 542-557) currently closes the notch after 100ms if not hovering and not in battery popover:

```swift
if self.vm.notchState == .open && !self.vm.isBatteryPopoverActive && !SharingStateManager.shared.preventNotchClose {
    self.vm.close()
}
```

**Modification**: Add `!ClickForwardingManager.shared.isDropdownActive` to the guard:

```swift
if self.vm.notchState == .open
    && !self.vm.isBatteryPopoverActive
    && !SharingStateManager.shared.preventNotchClose
    && !ClickForwardingManager.shared.isDropdownActive {
    self.vm.close()
}
```

This pattern appears in multiple places in ContentView. All auto-close checks must include the dropdown-active guard:

- **Line 150-161**: `.onReceive(NotificationCenter.default.publisher(for: .sharingDidFinish))` handler
- **Line 170-183**: `.onChange(of: vm.isBatteryPopoverActive)` handler  
- **Line 542-557**: hover-leave handler (primary)

### 2. BoringViewModel.swift: close() (line 200-219)

Add a guard at the top of `close()`:

```swift
func close() {
    // Do not close while a dropdown menu from a hidden icon is active
    if ClickForwardingManager.shared.isDropdownActive {
        return
    }
    // Do not close while a share picker or sharing service is active
    if SharingStateManager.shared.preventNotchClose {
        return
    }
    // ... rest of existing close logic
}
```

This follows the exact same pattern as the existing `SharingStateManager.shared.preventNotchClose` guard.

### 3. Post-Dismissal Close

When `exitDropdownActiveState()` fires and `isDropdownActive` becomes false, the panel should check if the mouse is still hovering. If not, close the panel:

In `exitDropdownActiveState()`, after setting `isDropdownActive = false`:

```swift
// After dropdown closes, check if we should close the panel
Task { @MainActor in
    try? await Task.sleep(for: .milliseconds(200))
    // Find the relevant BoringViewModel and check hover state
    // The panel's onHover handler will naturally close it if the mouse has left
}
```

In practice, the panel's existing `onHover` mechanism handles this. When the user moves the mouse away from the dropdown menu, the panel's hover region detects mouse-leave and fires the close logic (which now succeeds because `isDropdownActive` is false).

## Edge Cases

### App Quit While Dropdown Open

If the owning app terminates while its dropdown is open:

- The AXObserver becomes invalid (no callback fires)
- The 10-second timeout fires as a safety net and calls `exitDropdownActiveState()`
- The `NSWorkspace.didTerminateApplicationNotification` fires; MenuBarItemDetector removes the item from the list

### Multiple Rapid Clicks

If the user clicks another hidden icon while a dropdown is already active:

1. `exitDropdownActiveState()` is called first (cleans up previous observer/timeout)
2. The new `performClick(on:)` proceeds normally
3. `enterDropdownActiveState(for:)` is called for the new item

### Right-Click

Phase 1 does not handle right-click (secondary click) on hidden icons. All clicks are forwarded as primary (left) clicks. This is consistent with how macOS menu bar items primarily respond to left-click. Right-click behaviour can be added in a future phase if needed.

### Custom NSView Status Items

Some apps (e.g., Bartender, iStatMenus) use custom `NSView`-based status items that may not respond to `kAXPressAction`. For these:

1. AXPress will fail (return `.actionUnsupported` or `.cannotComplete`)
2. The CGEvent fallback fires
3. CGEvent click at the item's frame midpoint triggers the `mouseDown` handler on the custom NSView
4. This works because the item IS in the menu bar; it is just hidden behind the notch visually

### Panel Z-Order

The notch panel window (`BoringNotchSkyLightWindow`) is at level `mainMenu + 3`. Native dropdown menus from menu bar items render at the menu bar level. The dropdown will appear BELOW the notch panel in z-order.

This is acceptable because:
- The dropdown opens at the menu bar position (top of screen), which is spatially near the notch panel but not overlapping the panel content
- The user's mouse moves to the dropdown to interact with it
- The panel is positioned at the centre-top of the screen; dropdown menus appear at the item's original position (which may be under the notch, but the dropdown extends downward into visible space)

If z-order becomes a problem during implementation, the panel's window level can be temporarily lowered to `mainMenu + 1` while `isDropdownActive` is true.

## Logging

All operations log via `os.Logger` with category `"ClickForwarding"`:

| Level | What |
|-------|------|
| `.info` | Click attempt, success, state transitions |
| `.warning` | AXPress failure (before fallback), AXObserver creation failure |
| `.error` | CGEvent creation failure, no screen found for coordinates |
| `.debug` | Coordinate conversions, timeout triggers |

This uses `os.Logger` (structured logging) rather than the existing `Logger` struct in `boringNotch/utils/Logger.swift` (which uses `print()`). The `os.Logger` output is visible in Console.app with filtering, which is more useful for debugging AX interactions.
