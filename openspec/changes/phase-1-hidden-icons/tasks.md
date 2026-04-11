# Tasks: Phase 1 Implementation Order

## Build Order

Tasks are ordered by dependency. Each task lists its prerequisites, files touched, and acceptance criteria. A Sonnet-class model should be able to implement each task independently given the spec files and this ordering.

---

## Task 1: Data Model

**Prerequisites**: None

**Files**:
- Create: `boringNotch/models/HiddenMenuBarItem.swift`
- Modify: `boringNotch/models/Constants.swift`

**Work**:

1. Create `HiddenMenuBarItem` struct as specified in `specs/hidden-icon-detection/spec.md` (Data Model section)
   - Properties: `id`, `pid`, `bundleIdentifier`, `appName`, `axIdentifier`, `title`, `frame`, `element`, `iconImage`
   - Conform to `Identifiable`, `Hashable`
   - `Hashable`/`Equatable` based on `id` only (exclude `element` and `iconImage`)

2. Add Defaults key in `Constants.swift`:
   ```swift
   // MARK: Hidden Menu Bar Icons
   static let showHiddenMenuBarIcons = Key<Bool>("showHiddenMenuBarIcons", default: true)
   ```
   Add this after the existing "Advanced Settings" section (around line 191).

3. Add notification name in `Constants.swift` (inside the existing `extension Notification.Name` block, around line 40-42):
   ```swift
   static let hiddenMenuBarIconsSettingChanged = Notification.Name("hiddenMenuBarIconsSettingChanged")
   ```

**Acceptance**: Project compiles. `HiddenMenuBarItem` can be instantiated. `Defaults[.showHiddenMenuBarIcons]` returns `true`.

---

## Task 2: MenuBarItemDetector

**Prerequisites**: Task 1

**Files**:
- Create: `boringNotch/managers/MenuBarItemDetector.swift`

**Work**:

1. Create `MenuBarItemDetector` as specified in `specs/hidden-icon-detection/spec.md`
2. Implement `init()` (private, singleton via `static let shared`)
3. Implement `startObserving()`:
   - Register for `NSWorkspace.didLaunchApplicationNotification`
   - Register for `NSWorkspace.didTerminateApplicationNotification`
   - Register for `NSApplication.didChangeScreenParametersNotification`
   - Call `refresh()` on each notification
4. Implement `stopObserving()`:
   - Remove all observers
   - Cancel refresh task
   - Clear `hiddenItemsByScreen`
5. Implement `refresh()` (debounced):
   - Cancel existing `refreshTask`
   - Create new task with 200ms debounce (`Task.sleep(for: .milliseconds(200))`)
   - Call `performEnumerationAndClassification()`
   5b. Implement `refreshImmediate()` (synchronous, no debounce):
   - Cancel existing `refreshTask`
   - Call `performEnumerationAndClassification()` directly
   - Used by `ClickForwardingManager.performClick()` where results are needed immediately
   5c. Extract `performEnumerationAndClassification()`:
   - Call `enumerateAllMenuBarItems()`
   - For each screen in `NSScreen.screens`, classify items
   - Group by screen UUID, publish to `hiddenItemsByScreen`
   5d. Implement `startPeriodicRefresh()` and `stopPeriodicRefresh()`:
   - Called by `BoringViewModel.open()` and `close()` respectively
   - 10-second timer that calls `refresh()` while the panel is open
6. Implement `enumerateAllMenuBarItems()`:
   - Iterate `NSWorkspace.shared.runningApplications` where `isFinishedLaunching`
   - For each: `AXUIElementCreateApplication(pid)`
   - Query `"AXExtrasMenuBar"` attribute
   - Get children, extract frame/identifier/title per child
   - Build `HiddenMenuBarItem` with dedup key as specified
   - Log failures at `.debug` level via `os.Logger`
7. Implement `classifyItem(_:screen:)`:
   - Call `computeNotchDeadZone(for:)` 
   - Return true if > 50% overlap or fully inside dead zone bounds
8. Implement `computeNotchDeadZone(for:)`:
   - Check `screen.safeAreaInsets.top > 0`
   - Use `auxiliaryTopLeftArea` and `auxiliaryTopRightArea` to compute bounds
   - Return nil if no notch present
9. Implement `captureIconImage(for:frame:)`:
   - Try `kAXImageAttribute` first (may not exist)
   - Fallback: `CGWindowListCreateImage` with the item's frame region
   - Return nil if both fail
10. Implement `items(forScreen:)` convenience accessor

**Acceptance**: `MenuBarItemDetector.shared.refresh()` populates `hiddenItemsByScreen` with correct items on a MacBook with a notch and several menu bar apps. External displays show empty arrays. Calling `startObserving()` and quitting/launching an app triggers a refresh.

---

## Task 3: BoringViewModel Integration

**Prerequisites**: Task 2

**Files**:
- Modify: `boringNotch/models/BoringViewModel.swift`

**Work**:

1. Add published property (after existing `@Published` declarations, around line 38):
   ```swift
   @Published var hiddenIconItems: [HiddenMenuBarItem] = []
   ```

2. In `init(screenUUID:)`, after the `setupDetectorObserver()` call (line 69), add subscription:
   ```swift
   setupHiddenIconSubscription()
   ```

3. Add private method:
   ```swift
   private func setupHiddenIconSubscription() {
       guard let uuid = screenUUID else { return }
       MenuBarItemDetector.shared.$hiddenItemsByScreen
           .map { $0[uuid] ?? [] }
           .removeDuplicates()
           .receive(on: RunLoop.main)
           .assign(to: \.hiddenIconItems, on: self)
           .store(in: &cancellables)
   }
   ```

4. In `open()` (line 192-198), add refresh call and height adjustment:
   ```swift
   func open() {
       // Refresh hidden icons when panel opens
       MenuBarItemDetector.shared.refresh()

       var targetSize = openNotchSize
       if !hiddenIconItems.isEmpty && Defaults[.showHiddenMenuBarIcons] {
           targetSize.height += 28
       }
       self.notchSize = targetSize
       self.notchState = .open

       MusicManager.shared.forceUpdate()
   }
   ```

5. In `close()` (line 200-219), add guard after the existing `SharingStateManager` check:
   ```swift
   // Do not close while a hidden icon dropdown menu is active
   if ClickForwardingManager.shared.isDropdownActive {
       return
   }
   ```

**Acceptance**: `vm.hiddenIconItems` updates when `MenuBarItemDetector` publishes new data. Panel opens to an adjusted height when hidden icons are present. Panel refuses to close when `ClickForwardingManager.shared.isDropdownActive` is true.

---

## Task 4: ClickForwardingManager

**Prerequisites**: Task 1

**Files**:
- Create: `boringNotch/managers/ClickForwardingManager.swift`

**Work**:

1. Create `ClickForwardingManager` as specified in `specs/click-forwarding/spec.md`
2. Implement `performClick(on:)`:
   - Call `MenuBarItemDetector.shared.refreshImmediate()` (synchronous, no debounce)
   - Verify item still exists in refreshed list by id
   - Try AXPress, fall back to CGEvent
   - Enter dropdown-active state
3. Implement `performAXPress(on:)`:
   - `AXUIElementPerformAction(element, kAXPressAction as CFString)`
   - Return `result == .success`
4. Implement `performCGEventClick(at:)`:
   - Convert AppKit coordinates to CG coordinates
   - Create and post mouseDown + mouseUp events
   - 50ms delay between events
5. Implement `enterDropdownActiveState(for:)`:
   - Set `isDropdownActive = true`
   - Start AXObserver for `kAXMenuClosedNotification`
   - Start 10-second timeout
   - Observe frontmost app changes
6. Implement `exitDropdownActiveState()`:
   - Set `isDropdownActive = false`
   - Cancel timeout
   - Remove observers
7. Implement `observeMenuClosed(for:)`:
   - `AXObserverCreate` with callback
   - `AXObserverAddNotification` for `kAXMenuClosedNotification`
   - Add to main run loop
8. Implement `startDismissalTimeout()`:
   - Cancel existing timeout task
   - Create task that sleeps 10 seconds then calls `exitDropdownActiveState()`

**Acceptance**: Calling `performClick(on:)` with a valid item opens the app's dropdown menu. `isDropdownActive` becomes true. After the dropdown closes (or after 10 seconds), `isDropdownActive` becomes false.

---

## Task 5: HiddenIconRow View

**Prerequisites**: Task 1

**Files**:
- Create: `boringNotch/components/Notch/HiddenIconRow.swift`

**Work**:

1. Create `HiddenIconRow` as specified in `specs/hidden-icon-display/spec.md`
2. Accept `items: [HiddenMenuBarItem]` and `onItemClick: (HiddenMenuBarItem) -> Void`
3. Read `vm.notchState` from `@EnvironmentObject` to switch between compact and expanded layouts
4. Compact layout (closed state):
   - Icon size: `vm.effectiveClosedNotchHeight - 8`
   - `HStack(spacing: 2)` in `ScrollView(.horizontal, showsIndicators: false)`
   - Frame height: `vm.effectiveClosedNotchHeight`
5. Expanded layout (open state):
   - Icon size: 22 points
   - `HStack(spacing: 4)` in `ScrollView(.horizontal, showsIndicators: false)`
   - Frame height: 28 points
   - Bottom separator: `Divider().opacity(0.15)`
6. Each icon:
   - `Button` with plain style
   - Image from `item.iconImage`, fallback to app icon, fallback to `Image(systemName: "app.fill")`
   - `.help(item.appName)` tooltip
   - `.brightness(isHovered ? 0.2 : 0)` hover effect (use `@State var hoveredItemID`)
   - `.accessibilityLabel("\(item.appName) menu bar item")`
7. Row container: `.accessibilityLabel("Hidden menu bar icons")`
8. Transition: `.opacity.combined(with: .move(edge: .top))`

**Acceptance**: View renders a horizontal row of icon buttons. Tapping an icon calls `onItemClick`. View adapts between compact and expanded sizes based on `vm.notchState`. Empty items array renders nothing.

---

## Task 6: ContentView Integration

**Prerequisites**: Tasks 3, 4, 5

**Files**:
- Modify: `boringNotch/ContentView.swift`

**Work**:

1. Add import/observation for `ClickForwardingManager` if needed (it is a singleton, accessed via `ClickForwardingManager.shared`)

2. In `computedChinWidth` (around line 61), add condition for hidden icons in closed state. After the existing `showNotHumanFace` condition (line 73-78), before the closing brace:
   ```swift
   } else if !coordinator.expandingView.show && vm.notchState == .closed
       && !vm.hiddenIconItems.isEmpty && Defaults[.showHiddenMenuBarIcons]
       && !vm.hideOnClosed
   {
       chinWidth += CGFloat(min(vm.hiddenIconItems.count, 8)) * (max(0, vm.effectiveClosedNotchHeight - 8) + 2)
   }
   ```

3. In `NotchLayout()` function, modify the open-state header section (around line 295-298):
   ```swift
   } else if vm.notchState == .open {
       if !vm.hiddenIconItems.isEmpty && Defaults[.showHiddenMenuBarIcons] {
           HiddenIconRow(
               items: vm.hiddenIconItems,
               onItemClick: { item in
                   ClickForwardingManager.shared.performClick(on: item)
               }
           )
           .frame(height: 28)
           .environmentObject(vm)
       }
       BoringHeader()
           .frame(height: max(24, vm.effectiveClosedNotchHeight))
           .opacity(gestureProgress != 0 ? 1.0 - min(abs(gestureProgress) * 0.1, 0.3) : 1.0)
   }
   ```

4. In `NotchLayout()` function, modify the closed-state empty spacer (around line 299-301):
   ```swift
   } else if !vm.hiddenIconItems.isEmpty && Defaults[.showHiddenMenuBarIcons] {
       HiddenIconRow(
           items: vm.hiddenIconItems,
           onItemClick: { item in
               ClickForwardingManager.shared.performClick(on: item)
           }
       )
       .frame(height: vm.effectiveClosedNotchHeight)
       .environmentObject(vm)
   } else {
       Rectangle().fill(.clear).frame(width: vm.closedNotchSize.width - 20, height: vm.effectiveClosedNotchHeight)
   }
   ```

5. Add dropdown-active guard to all auto-close locations:

   **handleHover() hover-leave branch** (around line 552):
   Add `&& !ClickForwardingManager.shared.isDropdownActive` to the close condition.

   **onReceive(.sharingDidFinish) handler** (around line 156):
   Add `&& !ClickForwardingManager.shared.isDropdownActive` to the close condition.

   **onChange(of: vm.isBatteryPopoverActive) handler** (around line 177):
   Add `&& !ClickForwardingManager.shared.isDropdownActive` to the close condition.

6. Add `@Default(.showHiddenMenuBarIcons) var showHiddenMenuBarIcons` at the top of ContentView if needed for reactivity (or use `Defaults[.showHiddenMenuBarIcons]` inline, which is already reactive via Defaults library).

**Acceptance**: Hidden icons appear in the closed notch when no other content is active. Hidden icons appear above the header in the open notch. Clicking an icon triggers the dropdown. Panel does not auto-close while dropdown is active.

---

## Task 7: AppDelegate Wiring

**Prerequisites**: Tasks 2, 3

**Files**:
- Modify: `boringNotch/boringNotchApp.swift`

**Work**:

1. In `applicationDidFinishLaunching()` (around line 438, after `previousScreens = NSScreen.screens`), add:
   ```swift
   // Start hidden menu bar icon detection
   if Defaults[.showHiddenMenuBarIcons] {
       MenuBarItemDetector.shared.startObserving()
   }
   ```

2. Add observer for settings change (near the other notification observers, around line 330):
   ```swift
   NotificationCenter.default.addObserver(
       forName: Notification.Name.hiddenMenuBarIconsSettingChanged, object: nil, queue: nil
   ) { [weak self] _ in
       Task { @MainActor in
           if Defaults[.showHiddenMenuBarIcons] {
               MenuBarItemDetector.shared.startObserving()
           } else {
               MenuBarItemDetector.shared.stopObserving()
           }
       }
   }
   ```

3. In `applicationWillTerminate()` (around line 88, before `MusicManager.shared.destroy()`), add:
   ```swift
   MenuBarItemDetector.shared.stopObserving()
   ```

4. Add import for Defaults at top if not already present (it is already imported via other files in the module).

**Acceptance**: MenuBarItemDetector starts observing on app launch when the feature is enabled. Stops on app termination. Toggling the setting starts/stops the detector.

---

## Task 8: Settings Toggle

**Prerequisites**: Task 1

**Files**:
- Modify: `boringNotch/components/Settings/SettingsView.swift`

**Work**:

1. Examine the existing SettingsView structure to find the General section
2. Add a toggle:
   ```swift
   Toggle("Show hidden menu bar icons", isOn: Defaults.binding(.showHiddenMenuBarIcons))
   ```
3. Add descriptive text below: "Display menu bar icons hidden behind the notch. Requires Accessibility permission."
4. When the toggle changes, post the notification:
   ```swift
   .onChange(of: showHiddenMenuBarIcons) { _, _ in
       NotificationCenter.default.post(name: .hiddenMenuBarIconsSettingChanged, object: nil)
   }
   ```

**Acceptance**: Toggle appears in Settings. Changing it persists the preference and starts/stops detection.

---

## Implementation Notes

### Build Order Summary

```
Task 1 (Data Model)
    |
    +---> Task 2 (MenuBarItemDetector)
    |         |
    |         +---> Task 3 (BoringViewModel Integration)
    |         |         |
    |         +---> Task 7 (AppDelegate Wiring) ----+
    |                                                |
    +---> Task 4 (ClickForwardingManager)            |
    |                                                |
    +---> Task 5 (HiddenIconRow View)                |
    |                                                |
    +---> Task 8 (Settings Toggle)                   |
              |                                      |
              +---> Task 6 (ContentView Integration) +
                    (requires 3, 4, 5)
```

Tasks 1-5 and 8 can be partially parallelised. Task 6 is the final integration that wires everything together. Task 7 connects the lifecycle.

### Testing Approach

Phase 1 does not include unit tests (boring.notch has no test target). Testing is manual:

1. **Detection**: Run on a MacBook with a notch, with 15+ menu bar items. Verify that items behind the notch appear in the row.
2. **Click forwarding**: Click each detected icon. Verify the native dropdown opens.
3. **Dismissal**: Verify panel stays open while dropdown is visible. Verify panel closes normally after dropdown dismisses.
4. **Display switching**: Connect an external display. Verify the row disappears on the external display. Disconnect. Verify the row reappears.
5. **Feature toggle**: Disable in settings. Verify row disappears. Re-enable. Verify row reappears.
6. **Existing features**: Verify media controls, shelf, HUD, battery, calendar, webcam all still work.

### Files to Add to Xcode Project

All new `.swift` files must be added to the Xcode project file (`boringNotch.xcodeproj`). They should be placed in the appropriate groups:

- `boringNotch/models/HiddenMenuBarItem.swift` -> Models group
- `boringNotch/managers/MenuBarItemDetector.swift` -> managers group
- `boringNotch/managers/ClickForwardingManager.swift` -> managers group
- `boringNotch/components/Notch/HiddenIconRow.swift` -> components/Notch group
