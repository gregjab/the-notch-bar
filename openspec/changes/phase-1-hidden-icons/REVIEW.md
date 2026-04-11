# Spec Review: Phase 1 Hidden Icons

## Verdict: APPROVED_WITH_NOTES

The specs are thorough, well-structured, and the architecture decisions are sound. The integration approach correctly mirrors existing patterns (SharingStateManager, per-screen BoringViewModel). However, there are several line number inaccuracies, one incorrect coordinate conversion formula, and a few gaps that would trip up a build agent. Nothing requires a full rewrite, but the items below need attention before handing to Sonnet.

## Critical Issues (must fix before build)

1. **CGEvent coordinate conversion formula is wrong (click-forwarding/spec.md, line 93-95)**
   The spec gives:
   ```swift
   let cgPoint = CGPoint(
       x: point.x,
       y: screen.frame.height - (point.y - screen.frame.origin.y) + screen.frame.origin.y
   )
   ```
   This double-adds `screen.frame.origin.y`. The correct conversion from AppKit (bottom-left origin of primary screen) to Quartz (top-left origin of primary screen) is:
   ```swift
   let mainScreenHeight = NSScreen.screens.first?.frame.height ?? 0
   let cgPoint = CGPoint(x: point.x, y: mainScreenHeight - point.y)
   ```
   CGEvent coordinates are relative to the primary display's top-left corner, and AXFrame coordinates are relative to the primary display's bottom-left corner. The per-screen frame origin is irrelevant for this conversion. The spec's own "Coordinate system note" (line 121-122) states the correct formula (`cgY = mainScreenHeight - appKitY`) but the code block above it implements something different. The build agent will use the code block, not the comment. Fix the code.

2. **`kAXExtrasMenuBarAttribute` is NOT a system constant (hidden-icon-detection/spec.md, line 108)**
   The spec references `kAXExtrasMenuBarAttribute` as if it is a pre-defined constant like `kAXMenuBarAttribute`. It is not. The string `"AXExtrasMenuBar"` exists as an attribute name you can query, but there is no `kAXExtrasMenuBarAttribute` symbol in the Accessibility framework headers. The spec correctly notes the string value `"AXExtrasMenuBar"` in parentheses, but the build agent may try to use the constant name and get a compile error. Change all references to use the string literal `"AXExtrasMenuBar" as CFString` explicitly, and note that this is an undocumented attribute (present since macOS 10.12 but not in public headers).

3. **`refresh()` is described as both async (debounced via Task.sleep) and "synchronous on MainActor" (click-forwarding/spec.md, line 57)**
   The detection spec says `refresh()` creates a debounced Task with 200ms sleep. The click-forwarding spec says `performClick()` calls `refresh()` "synchronous on MainActor" before looking up the item. These are contradictory. If refresh is debounced, calling it from `performClick` would not have results ready immediately. The build agent needs clear guidance: either `performClick` should await a non-debounced refresh, or it should call a separate synchronous `refreshNow()` method. Recommend adding a `refreshImmediate()` method that skips the debounce and runs enumeration synchronously, and have `performClick` call that instead.

4. **`kAXMenuClosedNotification` may not exist as a named constant (click-forwarding/spec.md, line 145, 162, 187)**
   Similar to issue 2, `kAXMenuClosedNotification` is not a public Accessibility API constant. The correct notification name string is `"AXMenuClosed"`. The build agent should use `"AXMenuClosed" as CFString` directly. Also note: this notification fires on the application element, not necessarily on the menu bar item element. The `AXObserverAddNotification` call may need to observe the application-level AXUIElement (created via `AXUIElementCreateApplication(pid)`) rather than `item.element`. This is a known AX behaviour where menu notifications are delivered at the app level. If observed on the wrong element, the callback will never fire and only the 10-second timeout will work, which is a poor UX. The spec should clarify which element to observe.

## Important Notes (track during build)

1. **`usleep(50_000)` blocks the main thread (click-forwarding/spec.md, line 114)**
   The `performCGEventClick` method uses `usleep(50_000)` for a 50ms delay between mouseDown and mouseUp. Since `ClickForwardingManager` is `@MainActor`, this blocks the main thread for 50ms. This is technically acceptable for a fallback path but should be documented as intentional. A better approach would be `try? await Task.sleep(for: .milliseconds(50))` if the method is made async, but that changes the call signature. Flag for the build agent to be aware of.

2. **No periodic refresh timer implementation detail (hidden-icon-detection/spec.md, line 170)**
   The spec mentions "Timer, every 10 seconds while panel is open" as a refresh trigger but does not specify how the detector knows the panel is open. The detector is a singleton with no reference to any BoringViewModel. Options: (a) `BoringViewModel.open()` starts a timer on the detector, `close()` stops it; (b) the detector observes a notification. The spec should specify this wiring explicitly, or the build agent will have to guess.

3. **`BoringViewModel.open()` modification overwrites existing logic (tasks.md, Task 3, line 122-137)**
   The spec shows replacing the current `open()` body. The current `open()` at line 192-198 sets `notchSize = openNotchSize`, then sets `notchState = .open`, then calls `MusicManager.shared.forceUpdate()`. The spec's replacement changes the first line to `var targetSize = openNotchSize` and conditionally adds 28. This is correct but the build agent must preserve the `MusicManager.shared.forceUpdate()` call. The spec code snippet does include it, so this should be fine, but worth noting.

4. **`screen.auxiliaryTopLeftArea` and `auxiliaryTopRightArea` are Optional (hidden-icon-detection/spec.md, line 134)**
   The existing code in `sizing/matters.swift` (line 53-54) correctly unwraps these as optionals with `if let`. The spec's pseudocode does not show optional unwrapping. The build agent must handle the nil case (return nil from `computeNotchDeadZone` if either is nil).

5. **Dead zone Y coordinates may be inverted (hidden-icon-detection/spec.md, line 137-138)**
   The spec says dead zone top = `screen.frame.maxY` and bottom = `screen.frame.maxY - screen.safeAreaInsets.top`. In AppKit coordinates (origin at bottom-left), `maxY` is the top of the screen. This means the dead zone rectangle has `origin.y = screen.frame.maxY - screen.safeAreaInsets.top` and `height = screen.safeAreaInsets.top`. The spec describes the edges correctly but a build agent constructing a CGRect needs to know: `CGRect(x: leftEdge, y: screen.frame.maxY - screen.safeAreaInsets.top, width: rightEdge - leftEdge, height: screen.safeAreaInsets.top)`. Make this explicit.

6. **`Notification.Name.hiddenMenuBarIconsSettingChanged` location is ambiguous (tasks.md, Task 1)**
   Task 1 says "Add notification name in `boringNotchApp.swift` or `Constants.swift`". The build agent needs a definitive location. The existing pattern for notification names is in `Constants.swift` (line 40-42 has `Notification.Name` extensions) and `SharingStateManager.swift` (line 13). Recommend `Constants.swift` to keep notification names together. Also note: the existing `Notification.Name` extension in Constants.swift uses a nested `extension Notification.Name { }` block. The new name should go in the same block.

7. **Settings toggle wiring uses `Notification` when Defaults observation would be simpler (tasks.md, Task 8)**
   The spec uses a custom `Notification.Name.hiddenMenuBarIconsSettingChanged` posted from an `onChange` handler to communicate the toggle change to AppDelegate. The Defaults library already supports `Defaults.publisher(.showHiddenMenuBarIcons)` which AppDelegate could observe directly, matching the pattern used by `BoringViewCoordinator` for `hudReplacement` (line 139). This would eliminate the custom notification name entirely. Not blocking, but a simplification the build agent could adopt.

8. **`handleHover` line references are off (click-forwarding/spec.md, line 218; tasks.md, Task 6)**
   The spec references `handleHover()` at "line 511-558" and the hover-leave close at "line 542-557". Actual source: `handleHover` starts at line 513, hover-leave branch starts at line 542, close call at line 552-554. These are close enough to find but not exact.

## Minor Observations

1. **No `import ApplicationServices` or `import CoreGraphics` mentioned for AX types.** `AXUIElement`, `AXUIElementCreateApplication`, `AXUIElementPerformAction`, `AXObserverCreate` etc. come from the ApplicationServices or Accessibility framework. The new files will need `import ApplicationServices` (or the more targeted `import Accessibility`). The spec shows `import AppKit` which re-exports most of this, but `AXObserverCreate` specifically requires ApplicationServices. Build agent should verify.

2. **`HiddenMenuBarItem.iconImage` is `var` but the struct is otherwise immutable.** This is intentional (set after creation during capture), but makes the struct non-trivially copyable. Since the struct conforms to `Hashable` excluding `iconImage`, this is fine, but the build agent should note that `iconImage` mutation after creation means the property needs to be `var`.

3. **The `computedChinWidth` addition (tasks.md, Task 6, line 239-247) references "line 73-78" for `showNotHumanFace`.** Actual lines: the `showNotHumanFace` condition is at lines 73-78, which is correct.

4. **The spec says the new Defaults key should go "after the Advanced Settings section (around line 191)" (tasks.md, Task 1).** Line 191 is the last entry in Advanced Settings (`hideTitleBar`). The `defaultMediaController` computed property starts at line 193. Adding the key at line 192 (between `hideTitleBar` and the computed property) would work, but it would be cleaner to add a new `// MARK: Hidden Menu Bar Icons` section before the helper computed property.

5. **`SharingStateManager.shared.preventNotchClose` is checked in `close()` as a guard return (BoringViewModel line 200-203).** The click-forwarding spec adds `ClickForwardingManager.shared.isDropdownActive` as another guard return in the same location. This is the correct pattern.

6. **The `hideOnClosed` guard in the chinWidth addition is important.** When `hideOnClosed` is true (fullscreen mode), the notch shrinks to nothing. The spec correctly includes `!vm.hideOnClosed` in the chinWidth condition.

7. **`applicationDidFinishLaunching` line reference.** The spec says "around line 438, after `previousScreens = NSScreen.screens`". Actual: `previousScreens = NSScreen.screens` is at line 438. Correct.

8. **`applicationWillTerminate` line reference.** The spec says "around line 88, before `MusicManager.shared.destroy()`". Actual: `MusicManager.shared.destroy()` is at line 85. The insert point at "around line 88" should be "around line 84" (before the `MusicManager.shared.destroy()` call).

## Line Number Verification

| Spec Reference | Claimed Line | Actual Line | Status |
|---|---|---|---|
| `NotchLayout()` function start | 246-247 | 246 | Correct |
| Battery expanding branch | 260 | 260 | Correct |
| MusicLiveActivity branch | 290-292 | 290-292 | Correct |
| `showNotHumanFace` branch | 293 | 293 | Correct |
| `vm.notchState == .open` (BoringHeader) | 295-298 | 295-298 | Correct |
| Clear Rectangle else branch | 299-301 | 299-301 | Correct |
| `computedChinWidth` start | ~line 61 | 61 | Correct |
| `showNotHumanFace` chin condition | 73-78 | 73-77 | Off by 1 (closing brace at 78) |
| `BoringViewModel.init(screenUUID:)` | 53 | 53 | Correct |
| `setupDetectorObserver()` call | 69 | 69 | Correct |
| `BoringViewModel.open()` | 192-198 | 192-198 | Correct |
| `BoringViewModel.close()` | 200-219 | 200-219 | Correct |
| `@Published` declarations area | ~line 38 | 19-41 range | Correct (area) |
| `handleHover()` | 511-558 | 513-558 | Start off by 2 |
| Hover-leave close line | 542-557 | 542-557 | Correct |
| `.onReceive(.sharingDidFinish)` | 150-161 | 149-161 | Off by 1 |
| `.onChange(of: vm.isBatteryPopoverActive)` | 170-183 | 170-183 | Correct |
| `applicationDidFinishLaunching` | 282 | 282 | Correct |
| `previousScreens = NSScreen.screens` | 438 | 438 | Correct |
| `applicationWillTerminate` cleanup area | ~88 | 75-89 (fn body) | Acceptable |
| `MusicManager.shared.destroy()` | ~88 | 85 | Off by 3 |
| `BoringViewCoordinator` AX lines | 138-175 | 138-174 | Off by 1 at end |
| `sizing/matters.swift` notch geometry | 53-57 | 53-57 | Correct |
| `Constants.swift` Advanced Settings section | ~191 | 190-191 | Correct |

## Spec-to-Spec Consistency Check

1. **detection spec vs click-forwarding spec on `refresh()` semantics**: Inconsistent. Detection spec defines `refresh()` as debounced (200ms Task.sleep). Click-forwarding spec calls `refresh()` and expects synchronous results on the next line. These cannot both be true. See Critical Issue 3.

2. **design.md vs tasks.md on startup wiring location**: design.md says "after line 438" in `applicationDidFinishLaunching()`. tasks.md Task 7 says "around line 438, after `previousScreens = NSScreen.screens`". These agree. However, design.md also says to add notification observers "near the other notification observers, around line 330". tasks.md Task 7 says the same. These agree but line 330 is in the middle of the notification observer block (the `expandedDragDetectionChanged` observer). The actual end of the observer block (before `DistributedNotificationCenter`) is around line 336. Close enough for a build agent to find the right spot.

3. **display spec vs tasks.md on HiddenIconRow parameters**: display spec (line 34-35) shows `items: [HiddenMenuBarItem]` and `onItemClick: (HiddenMenuBarItem) -> Void`. tasks.md Task 5 shows the same. Consistent.

4. **design.md vs detection spec on `hiddenItemsByScreen` type**: Both use `[String: [HiddenMenuBarItem]]`. Consistent.

5. **All three specs agree on `ClickForwardingManager.shared.isDropdownActive` as the guard condition.** Consistent across click-forwarding spec, display spec (implicit via ContentView guards), and tasks.md.

6. **design.md "Option A" height adjustment vs tasks.md Task 3**: Both show `targetSize.height += 28`. Consistent.

## Summary of Required Fixes Before Build

- Fix the CGEvent coordinate conversion code (Critical 1)
- Replace `kAXExtrasMenuBarAttribute` with string literal `"AXExtrasMenuBar" as CFString` (Critical 2)
- Add a non-debounced refresh path for `performClick` (Critical 3)
- Replace `kAXMenuClosedNotification` with `"AXMenuClosed" as CFString` and clarify which element to observe (Critical 4)
- Pick a definitive location for `Notification.Name.hiddenMenuBarIconsSettingChanged` (Note 6)
- Specify how the 10-second periodic timer knows the panel is open (Note 2)

Everything else is solid and can be tracked during the build without spec revisions.
