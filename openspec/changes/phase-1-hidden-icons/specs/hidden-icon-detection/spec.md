# Spec: Hidden Icon Detection Subsystem

## Overview

MenuBarItemDetector is a singleton `@MainActor` class that discovers menu bar icons hidden behind the MacBook notch using the macOS Accessibility API. It publishes a per-screen dictionary of hidden items that the UI layer observes.

## Data Model

### File: `boringNotch/models/HiddenMenuBarItem.swift` (new)

```swift
import AppKit

struct HiddenMenuBarItem: Identifiable, Hashable {
    /// Unique key for dedup and identity.
    /// Format: "\(pid):\(bundleID ?? "unknown"):\(axIdentifier ?? title ?? "\(Int(frame.origin.x))")"
    let id: String

    /// The PID of the owning application
    let pid: pid_t

    /// Bundle identifier of the owning app (nil for system agents)
    let bundleIdentifier: String?

    /// The app's localised name
    let appName: String

    /// AXIdentifier from the menu bar item (may be nil)
    let axIdentifier: String?

    /// AXTitle from the menu bar item (may be nil)
    let title: String?

    /// The AXFrame of the item in screen coordinates (logical points, not pixels)
    let frame: CGRect

    /// The live AXUIElement reference for performing actions
    let element: AXUIElement

    /// Snapshot of the icon image, captured via AX or CGWindow, for display in the row.
    /// Nil if capture failed; UI falls back to app icon.
    var iconImage: NSImage?

    // MARK: - Hashable / Equatable (exclude element and iconImage)
    static func == (lhs: HiddenMenuBarItem, rhs: HiddenMenuBarItem) -> Bool {
        lhs.id == rhs.id
    }
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
```

### Identity and Dedup

The `id` field must be deterministic across refreshes so SwiftUI identity is stable:

1. If `axIdentifier` is non-nil and non-empty: `"\(pid):\(bundleID):\(axIdentifier)"`
2. Else if `title` is non-nil and non-empty: `"\(pid):\(bundleID):\(title)"`
3. Else fallback: `"\(pid):\(bundleID ?? "unknown"):\(Int(frame.origin.x))"`

This matches the dedup strategy from the original nook-fixer design.

## MenuBarItemDetector

### File: `boringNotch/managers/MenuBarItemDetector.swift` (new)

```swift
import AppKit
import Combine
import os.log

@MainActor
final class MenuBarItemDetector: ObservableObject {
    static let shared = MenuBarItemDetector()

    /// Per-screen hidden items. Key is display UUID string.
    @Published private(set) var hiddenItemsByScreen: [String: [HiddenMenuBarItem]] = [:]

    private let logger = os.Logger(subsystem: Bundle.main.bundleIdentifier!, category: "MenuBarItemDetector")
    private var workspaceObservers: [Any] = []
    private var refreshTask: Task<Void, Never>?

    private init() { ... }
    deinit { ... }

    // Public API
    func startObserving() { ... }
    func stopObserving() { ... }
    func refresh() { ... }          // Debounced (200ms). Use for bulk triggers (app launch, screen change).
    func refreshImmediate() { ... } // Synchronous, no debounce. Use when results are needed immediately (e.g., before click forwarding).
    func items(forScreen uuid: String) -> [HiddenMenuBarItem] { ... }

    // Internal
    private func enumerateAllMenuBarItems() -> [HiddenMenuBarItem] { ... }
    private func classifyItem(_ item: HiddenMenuBarItem, screen: NSScreen) -> Bool { ... }
    private func computeNotchDeadZone(for screen: NSScreen) -> CGRect? { ... }
    private func captureIconImage(for element: AXUIElement, frame: CGRect) -> NSImage? { ... }
}
```

### Enumeration Algorithm

`enumerateAllMenuBarItems()`:

1. Get `NSWorkspace.shared.runningApplications`
2. Filter to `.isFinishedLaunching == true`
3. For each app, create `AXUIElementCreateApplication(app.processIdentifier)`
4. Query the **extras menu bar** attribute: `"AXExtrasMenuBar" as CFString` (string: `"AXExtrasMenuBar"`)
   - This is NOT `kAXMenuBarAttribute`. The extras menu bar is the right-side bar where third-party status items live.
   - If the attribute is not present or the value is nil, skip this app.
5. Get children of the extras menu bar: `kAXChildrenAttribute`
6. For each child (AXMenuBarItem):
   - Extract `kAXFrameAttribute` (AXValue of type CGRect)
   - Extract `kAXIdentifierAttribute` (String, may be nil)
   - Extract `kAXTitleAttribute` (String, may be nil)
   - Build `HiddenMenuBarItem` with the dedup key
7. Return the full list of discovered items

### Classification: Hidden vs Visible

`classifyItem(_:screen:)` returns `true` if the item is hidden behind the notch:

1. Compute the notch dead zone for the given screen using `computeNotchDeadZone(for:)`
2. Calculate the intersection area between the item's `frame` and the dead zone
3. If intersection area is > 50% of the item's area, classify as hidden
4. Additional boundary check: if the item's frame is entirely between the leftmost and rightmost edges of the dead zone, classify as hidden regardless of overlap percentage (handles items fully inside the notch)
5. Items whose frame has zero width or height are skipped (stale or invalid)

### Notch Dead Zone Computation

`computeNotchDeadZone(for:)`:

1. Check `screen.safeAreaInsets.top > 0` to confirm the screen has a notch. If not, return nil (no dead zone, no hidden items possible).
2. Use `screen.auxiliaryTopLeftArea` and `screen.auxiliaryTopRightArea` to compute the notch boundaries:
   - Dead zone left edge: `screen.frame.origin.x + auxiliaryTopLeftArea.width`
   - Dead zone right edge: `screen.frame.origin.x + screen.frame.width - auxiliaryTopRightArea.width`
   - Dead zone top: `screen.frame.maxY`
   - Dead zone bottom: `screen.frame.maxY - screen.safeAreaInsets.top`
3. This matches the geometry logic already used in `getClosedNotchSize()` in `sizing/matters.swift` (lines 53-57).

### Per-Screen Grouping

After enumeration and classification:

1. For each `NSScreen.screens`, compute the dead zone
2. Classify each item against each screen's dead zone
3. Group hidden items by screen UUID
4. Publish to `hiddenItemsByScreen`

In practice, items only hide on the built-in display (the one with a notch). External displays have `safeAreaInsets.top == 0`, so `computeNotchDeadZone` returns nil and no items are classified as hidden on those screens.

### Icon Image Capture

`captureIconImage(for:frame:)`:

1. First attempt: query `kAXImageAttribute` on the AXUIElement. If present, convert the returned `AXValue` (CGImage/NSImage reference) to NSImage.
2. Fallback: use `CGWindowListCreateImage` with the item's frame rect to capture a screenshot of just that region. Crop to the item bounds.
3. If both fail, return nil. The UI layer falls back to the app's dock icon via `NSWorkspace.shared.icon(forFile:)` or `NSRunningApplication.icon`.

### Refresh Triggers

`startObserving()` registers for:

| Trigger | Mechanism | Action |
|---------|-----------|--------|
| App launched | `NSWorkspace.didLaunchApplicationNotification` | `refresh()` |
| App terminated | `NSWorkspace.didTerminateApplicationNotification` | `refresh()` |
| Screen configuration changed | `NSApplication.didChangeScreenParametersNotification` | `refresh()` |
| Panel opened | Called explicitly from `BoringViewModel.open()` | `refresh()` |
| Periodic (safety net) | Timer, every 10 seconds while panel is open | `refresh()` — started by `BoringViewModel.open()` calling `MenuBarItemDetector.shared.startPeriodicRefresh()`, stopped by `BoringViewModel.close()` calling `MenuBarItemDetector.shared.stopPeriodicRefresh()` |

`refresh()` debounces: if called multiple times within 200ms, only the last invocation runs. Implementation via cancelling and recreating `refreshTask`.

### Clamshell Mode

When `NSScreen.screens` contains no screen with `safeAreaInsets.top > 0`, the built-in display is not active (lid closed, external display only). In this case:

- `hiddenItemsByScreen` is empty for all screens
- The UI row does not render
- No periodic refresh runs

When the lid opens again, `screenConfigurationDidChange` fires, `refresh()` runs, and items are re-detected.

### Error Handling

- AX calls can fail silently (return `AXError`). Log failures via `os.Logger` at `.debug` level, do not crash.
- If `AXIsProcessTrusted()` returns false, log a warning and publish empty results. The existing XPCHelperClient accessibility prompt flow handles requesting permission.
- Stale AXUIElement references (app quit since detection): handled at click time, not detection time. Detection refreshes on app terminate anyway.

### Threading

- All published properties are `@MainActor`
- Enumeration runs on `@MainActor` (AXUIElement APIs are not thread-safe and must run on the main thread)
- The `refresh()` method is async to allow debouncing but runs enumeration synchronously on MainActor

### Accessibility Permission

The main app process (not the XPC helper) needs `AXIsProcessTrusted() == true`. boring.notch already prompts for this when HUD replacement is enabled (`BoringViewCoordinator.init()`, lines 138-175 of `BoringViewCoordinator.swift`). 

For the hidden icon feature, if AX permission is not granted:
1. The feature silently produces no results (empty hidden items list)
2. A settings toggle for "Show hidden menu bar icons" includes a note that Accessibility permission is required
3. Enabling the toggle checks `AXIsProcessTrusted()` and prompts if needed, using the same pattern as `hudReplacement`

### Integration with Existing Code

| Existing component | Integration point |
|---|---|
| `BoringViewModel` | Add `@Published var hiddenIconItems: [HiddenMenuBarItem] = []`. In `open()`, call `MenuBarItemDetector.shared.refresh()`. Subscribe to `MenuBarItemDetector.shared.hiddenItemsByScreen` filtered by `self.screenUUID`. |
| `AppDelegate.screenConfigurationDidChange()` | Already posts screen change notification. MenuBarItemDetector observes this independently. No change to AppDelegate needed. |
| `XPCHelperClient` | Not used directly. Detection uses `AXIsProcessTrusted()` in the main process. |
| `Constants.swift` (Defaults.Keys) | Add `static let showHiddenMenuBarIcons = Key<Bool>("showHiddenMenuBarIcons", default: true)` |
