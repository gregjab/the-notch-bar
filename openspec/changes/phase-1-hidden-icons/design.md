# Design: Phase 1 Architecture and Integration

## Architecture Decisions

### D1: Inline Row, Not a New Tab

**Decision**: Hidden icons render as an inline row in the NotchLayout header section, not as a new tab alongside Home and Shelf.

**Rationale**: The requirements specify "persistent row at top of notch panel" visible in both compact and expanded views. A tab would hide icons behind an extra tap and would not be visible in the closed state. The inline approach matches how battery notifications and music live activity already work in boring.notch: they render directly in the header area based on state.

**Alternative rejected**: Adding `.hiddenIcons` to `NotchViews` enum and a third tab in `TabSelectionView`. This would require the user to navigate to the tab to see icons, defeating the purpose of always-visible access.

### D2: Detection in Main App Process, Not XPC Helper

**Decision**: MenuBarItemDetector runs in the main app process using `AXUIElementCreateApplication()` directly.

**Rationale**: The XPC helper (`BoringNotchXPCHelper`) is used for operations that need to run in a separate trust domain (keyboard brightness, screen brightness) or that benefit from process isolation. AXUIElement enumeration requires creating elements from PIDs of running apps, which works in any process that has AX trust. The main app already needs AX trust for HUD replacement. Running detection in the main process avoids XPC serialisation overhead for AXUIElement references (which are not serialisable across processes).

**Alternative rejected**: Adding detection methods to `BoringNotchXPCHelperProtocol`. This would require serialising item data across the XPC boundary and would not allow passing live AXUIElement references for click forwarding.

### D3: AXExtrasMenuBar, Not AXMenuBar

**Decision**: Query `kAXExtrasMenuBarAttribute` (the right-side extras/status menu bar) rather than `kAXMenuBarAttribute` (the left-side app menu bar).

**Rationale**: Third-party menu bar icons live in the extras menu bar. The left-side menu bar contains the app name and standard menus (File, Edit, View, etc.), which are never hidden behind the notch. Only extras overflow behind the notch when space is insufficient.

### D4: 50% Overlap Threshold for Classification

**Decision**: An item is classified as "hidden" if more than 50% of its frame area intersects with the notch dead zone.

**Rationale**: Items partially behind the notch (e.g., 30% occluded) are still partially clickable by the user. Items more than half hidden are effectively inaccessible. The 50% threshold is a reasonable balance. The original nook-fixer spec used the same threshold.

### D5: os.Logger Over Existing Logger Struct

**Decision**: New subsystems use `os.Logger` (Apple's structured logging) rather than the existing `Logger` struct in `utils/Logger.swift`.

**Rationale**: The existing `Logger` uses `print()` with emoji prefixes. It works but does not integrate with Console.app's filtering. AX debugging benefits enormously from structured logging with categories and levels. The existing `Logger` is not modified or replaced; new code simply uses the system logger.

### D6: Dismissal State in Separate Manager, Not in BoringViewModel

**Decision**: ClickForwardingManager owns the dismissal state machine independently of BoringViewModel.

**Rationale**: The dismissal state (idle vs dropdown-active) is a cross-cutting concern that affects multiple views and the ViewModel's close behaviour. Keeping it in a separate singleton follows the same pattern as `SharingStateManager.shared.preventNotchClose`, which already exists for the sharing sheet use case. BoringViewModel.close() checks ClickForwardingManager.shared.isDropdownActive the same way it checks SharingStateManager.shared.preventNotchClose.

### D7: No New Permissions UI for Phase 1

**Decision**: Reuse the existing Accessibility permission flow. Do not add a separate permission prompt for hidden icon detection.

**Rationale**: boring.notch already handles AX permission for HUD replacement in `BoringViewCoordinator.init()`. If AX is already granted, hidden icon detection works immediately. If not, the feature silently produces no results. The settings toggle for hidden icons notes that AX permission is required, and enabling it can prompt via the existing `XPCHelperClient.ensureAccessibilityAuthorization(promptIfNeeded:)` flow.

### D8: Per-Screen Hidden Items via BoringViewModel, Not Global

**Decision**: Each BoringViewModel instance holds its own `hiddenIconItems` array, filtered for its screen.

**Rationale**: In multi-display mode, each screen has its own BoringViewModel and its own notch panel window. Different screens have different dead zones (or no dead zone if external). The BoringViewModel subscribes to `MenuBarItemDetector.shared.hiddenItemsByScreen` filtered by `self.screenUUID`. This is consistent with how other per-screen state (notchSize, closedNotchSize, hideOnClosed) is handled.

## Integration Approach

### Data Flow

```
NSWorkspace.runningApplications
        |
        v
MenuBarItemDetector.shared
    .enumerateAllMenuBarItems()     -- AX enumeration
    .classifyItem(_:screen:)        -- per-screen dead zone check
    .hiddenItemsByScreen             -- @Published [String: [HiddenMenuBarItem]]
        |
        v
BoringViewModel (per screen)
    .hiddenIconItems                -- @Published [HiddenMenuBarItem]
    (subscribes to detector, filters by screenUUID)
        |
        v
ContentView -> NotchLayout -> HiddenIconRow
    (reads vm.hiddenIconItems, renders icons)
        |
        v  (on tap)
ClickForwardingManager.shared
    .performClick(on: item)         -- AXPress or CGEvent fallback
    .isDropdownActive               -- suppresses auto-close
```

### Subscription Wiring in BoringViewModel

In `BoringViewModel.init(screenUUID:)`, after the existing `setupDetectorObserver()` call:

```swift
// Subscribe to hidden menu bar items for this screen
if let uuid = screenUUID {
    MenuBarItemDetector.shared.$hiddenItemsByScreen
        .map { $0[uuid] ?? [] }
        .removeDuplicates()
        .receive(on: RunLoop.main)
        .assign(to: \.hiddenIconItems, on: self)
        .store(in: &cancellables)
}
```

### Startup Sequence

In `AppDelegate.applicationDidFinishLaunching()` (boringNotchApp.swift, after line 438):

```swift
// Start hidden menu bar icon detection
if Defaults[.showHiddenMenuBarIcons] {
    MenuBarItemDetector.shared.startObserving()
}
```

And observe the setting toggle:

```swift
NotificationCenter.default.addObserver(
    forName: Notification.Name.hiddenMenuBarIconsSettingChanged, object: nil, queue: nil
) { _ in
    Task { @MainActor in
        if Defaults[.showHiddenMenuBarIcons] {
            MenuBarItemDetector.shared.startObserving()
        } else {
            MenuBarItemDetector.shared.stopObserving()
        }
    }
}
```

### Cleanup

In `AppDelegate.applicationWillTerminate()` (line 75-89), add:

```swift
MenuBarItemDetector.shared.stopObserving()
```

## Risk Analysis

### R1: AXExtrasMenuBar Attribute Availability

**Risk**: `kAXExtrasMenuBarAttribute` may not be exposed by all apps or on all macOS versions.

**Mitigation**: The attribute has been available since macOS 10.12. If an app does not expose it, that app's items are simply not detected. This is acceptable: we detect what we can.

**Fallback**: For apps that only expose `kAXMenuBarAttribute`, we could fall back to querying that and filtering to right-side items by position. This is a Phase 2 enhancement if needed.

### R2: Performance of AX Enumeration

**Risk**: Enumerating all running apps' menu bar items on every refresh could be slow with many apps (50+).

**Mitigation**: 
- Debounce refreshes (200ms)
- Only refresh on meaningful triggers (app launch/quit, screen change, panel open)
- The 10-second periodic refresh only runs while the panel is open
- AX calls for menu bar items are lightweight (small tree, no deep traversal)

**Measured expectation**: 30 running apps, 2-3 AX calls per app = ~100 AX calls. Each takes <1ms. Total < 100ms. Acceptable for MainActor.

### R3: CGEvent Click Coordinate Accuracy

**Risk**: Coordinate conversion between AppKit (bottom-left origin) and CG (top-left origin) across multiple displays can produce incorrect click targets.

**Mitigation**: 
- Use the item's AXFrame directly (always in AppKit screen coordinates)
- Convert using the specific screen's geometry, not assuming main screen
- Log the computed coordinates at `.debug` level for troubleshooting
- AXPress is the primary path; CGEvent is only a fallback

### R4: Dropdown Z-Order Behind Panel

**Risk**: Native dropdown menus may render behind the notch panel window (which is at level mainMenu+3).

**Mitigation**:
- Accept this for Phase 1. Dropdown menus extend downward from the menu bar, and the notch panel is narrow at the top. Most of the dropdown content is below the panel.
- If problematic during QA: temporarily lower panel window level to `mainMenu + 1` while `isDropdownActive` is true, then restore on `exitDropdownActiveState()`.

### R5: AXIsProcessTrusted Race on First Launch

**Risk**: If the user has never granted AX permission, the feature produces no results on first launch, and the user may not realise why.

**Mitigation**:
- The feature defaults to enabled (`showHiddenMenuBarIcons = true`)
- If AX is not trusted and the user has hidden icons, the row is simply empty (no error shown)
- When the user enables HUD replacement (which prompts for AX), the hidden icon feature starts working immediately
- The settings toggle description mentions AX requirement
- Phase 2 could add a subtle one-time prompt or indicator

### R6: Stale Items After App Quit

**Risk**: User clicks an icon for an app that just quit. The AXUIElement is invalid.

**Mitigation**:
- `performClick()` calls `MenuBarItemDetector.shared.refresh()` before attempting the click
- If the item is no longer in the refreshed list, log and return
- The UI updates on the next publish cycle (typically within the same run loop)
- The `NSWorkspace.didTerminateApplicationNotification` observer triggers a refresh independently

## File Inventory

### New Files

| File | Lines (est.) | Purpose |
|------|-------------|---------|
| `boringNotch/models/HiddenMenuBarItem.swift` | ~45 | Data model |
| `boringNotch/managers/MenuBarItemDetector.swift` | ~250 | Detection singleton |
| `boringNotch/managers/ClickForwardingManager.swift` | ~180 | Click forwarding + dismissal state |
| `boringNotch/components/Notch/HiddenIconRow.swift` | ~120 | SwiftUI icon row view |

### Modified Files

| File | Nature of Change |
|------|-----------------|
| `boringNotch/models/BoringViewModel.swift` | Add `hiddenIconItems` property, subscription, open() height adjustment |
| `boringNotch/models/Constants.swift` | Add `showHiddenMenuBarIcons` Defaults key |
| `boringNotch/ContentView.swift` | Insert HiddenIconRow in NotchLayout, adjust computedChinWidth, add dropdown-active guards |
| `boringNotch/boringNotchApp.swift` | Initialise/teardown MenuBarItemDetector in AppDelegate |
| `boringNotch/components/Settings/SettingsView.swift` | Add toggle for hidden icon feature |

### Unchanged Files

All media controllers, shelf views, battery views, calendar views, webcam manager, XPC helper, tab selection, notch shape, window management. The feature is additive with surgical integration points.
