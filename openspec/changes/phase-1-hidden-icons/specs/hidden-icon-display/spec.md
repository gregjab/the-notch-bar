# Spec: Hidden Icon Display (UI Integration)

## Overview

HiddenIconRow is a SwiftUI view that renders detected hidden menu bar icons as a compact, horizontal row within the notch panel. It appears at the top of the NotchLayout header in ContentView, above all existing content. It is conditionally rendered: only visible when hidden items exist for the current screen.

## Display Behaviour

### When to Show

The row renders when ALL of these conditions are true:

1. `Defaults[.showHiddenMenuBarIcons]` is true (user has not disabled the feature)
2. `vm.hiddenIconItems.count > 0` (there are actually hidden items on this screen)
3. The notch panel is not in the hello animation state (`!coordinator.helloAnimationRunning`)

### When to Hide

The row is absent (not rendered, not hidden with opacity) when:

- No hidden items exist for the current screen (external display, or few menu bar items)
- The user has disabled the feature in settings
- The app is in clamshell mode with no built-in display active

## View: HiddenIconRow

### File: `boringNotch/components/Notch/HiddenIconRow.swift` (new)

```swift
import SwiftUI
import Defaults

struct HiddenIconRow: View {
    let items: [HiddenMenuBarItem]
    let onItemClick: (HiddenMenuBarItem) -> Void
    @EnvironmentObject var vm: BoringViewModel

    var body: some View {
        // Implementation below
    }
}
```

### Layout: Compact State (notch closed)

When `vm.notchState == .closed`:

- Row height: matches `vm.effectiveClosedNotchHeight` (same as the existing closed header content)
- Icons are rendered as small circles/squares, sized to `effectiveClosedNotchHeight - 8` points (e.g., ~24px on a standard notch)
- Horizontal layout: `HStack(spacing: 2)`
- If the number of icons exceeds what fits in the available width (the notch width minus some padding), the row scrolls horizontally. Use `ScrollView(.horizontal, showsIndicators: false)`.
- No labels, just icons
- The row replaces the clear spacer Rectangle that shows when no other closed-state content is active (ContentView.swift, line 300)

### Layout: Expanded State (notch open)

When `vm.notchState == .open`:

- Row renders above the BoringHeader, as the first child in the NotchLayout VStack
- Row height: 28 points
- Icons are slightly larger: 22x22 points
- `HStack(spacing: 4)` with horizontal scroll if overflow
- Each icon shows a tooltip (via `.help()` modifier) with the app name
- Row has subtle bottom separator: 0.5pt line in `Color.white.opacity(0.1)`
- Padding: `.horizontal(8)`, `.vertical(4)`

### Icon Rendering

Each icon button in the row:

```swift
Button {
    onItemClick(item)
} label: {
    Group {
        if let iconImage = item.iconImage {
            Image(nsImage: iconImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else if let bundleID = item.bundleIdentifier,
                  let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            // Fallback: app icon from bundle
            Image(nsImage: NSWorkspace.shared.icon(forFile: appURL.path))
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else {
            // Final fallback: generic app icon
            Image(systemName: "app.fill")
                .foregroundColor(.gray)
        }
    }
    .frame(width: iconSize, height: iconSize)
    .clipShape(RoundedRectangle(cornerRadius: 4))
}
.buttonStyle(PlainButtonStyle())
.help(item.appName)
```

### Animations

- Row appearance: `.transition(.opacity.combined(with: .move(edge: .top)))` with `.animation(.smooth(duration: 0.25))`
- Individual icons: fade in when added, fade out when removed (SwiftUI handles this via `ForEach` identity)
- No spring bounce on the row itself (it should feel informational, not playful)

## Integration into ContentView

### File: `boringNotch/ContentView.swift`

The HiddenIconRow is inserted into the `NotchLayout()` function. Here is the precise insertion point and modification:

#### Closed State Integration

In the `NotchLayout()` function (line 247), the current structure is:

```
VStack(alignment: .leading) {
    VStack(alignment: .leading) {
        if coordinator.helloAnimationRunning {
            ...
        } else {
            if /* battery expanding */ { ... }
            else if /* inline HUD */ { ... }
            else if /* music live activity */ { ... }
            else if /* not human face */ { ... }
            else if vm.notchState == .open { BoringHeader() ... }
            else { Rectangle().fill(.clear) ... }   // <-- line 300
            ...
        }
    }
}
```

The hidden icon row needs to appear in the closed state as an alternative to the empty clear Rectangle on line 300. Modify the else clause:

**Before (line 299-301):**
```swift
} else {
    Rectangle().fill(.clear).frame(width: vm.closedNotchSize.width - 20, height: vm.effectiveClosedNotchHeight)
}
```

**After:**
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

This means: when the notch is closed and there is no music playing, no battery notification, no HUD, no face animation, but there ARE hidden icons, show them instead of the empty spacer.

#### Open State Integration

When the notch is open, the header (BoringHeader) renders at line 295-298. The hidden icon row should appear ABOVE the header. Modify the `.open` branch:

**Before (line 295-298):**
```swift
} else if vm.notchState == .open {
    BoringHeader()
        .frame(height: max(24, vm.effectiveClosedNotchHeight))
        .opacity(gestureProgress != 0 ? 1.0 - min(abs(gestureProgress) * 0.1, 0.3) : 1.0)
}
```

**After:**
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

#### Coexistence with Music Live Activity

When music is playing and the notch is closed, the MusicLiveActivity view renders (line 290-292). In this case, the hidden icon row does NOT render in the closed state. This is correct because:

1. The closed state only has room for one content type at a time
2. Music live activity takes priority (user expectation from boring.notch)
3. Hidden icons are always accessible by opening the notch (hover/click/gesture)

The hidden icon row DOES render in the open state alongside everything else, because the open state has room for the row above the header.

#### Width Adjustment for Closed State

When hidden icons are shown in the closed state, the notch width should expand slightly to accommodate the icons (similar to how MusicLiveActivity expands the chin). In `computedChinWidth` (ContentView.swift, around line 61):

Add a new condition:

```swift
} else if !coordinator.expandingView.show && vm.notchState == .closed
    && !vm.hiddenIconItems.isEmpty && Defaults[.showHiddenMenuBarIcons]
    && !vm.hideOnClosed
{
    chinWidth += CGFloat(min(vm.hiddenIconItems.count, 8)) * (max(0, vm.effectiveClosedNotchHeight - 8) + 2)
}
```

This expands the notch width proportionally to the number of hidden icons (capped at 8 in the compact view).

## Open State Height Adjustment

The open notch height (`openNotchSize` in `sizing/matters.swift`) is currently fixed at 190 points. When the hidden icon row is present, the content needs 28 additional points. Two options:

**Option A (recommended): Dynamic height**
In `BoringViewModel.open()`, check if hidden items exist and adjust:

```swift
func open() {
    var targetSize = openNotchSize
    if !hiddenIconItems.isEmpty && Defaults[.showHiddenMenuBarIcons] {
        targetSize.height += 28
    }
    self.notchSize = targetSize
    self.notchState = .open
    MusicManager.shared.forceUpdate()
}
```

**Option B: Fixed height increase**
Always add 28 points. Simpler but wastes space when no hidden icons exist. Not recommended.

## Styling

- Background: transparent (inherits the `.black` background from NotchLayout)
- Icon tint: none (render the actual icon image, not tinted)
- Separator (open state only): `Divider().opacity(0.15)` below the row
- No emoji anywhere in the UI
- Hover effect on individual icons: slight brightness increase (`.brightness(isHovered ? 0.2 : 0)`)

## Settings Integration

Add a toggle in the Settings view under the General section:

```swift
Toggle("Show hidden menu bar icons", isOn: $showHiddenMenuBarIcons)
```

With a descriptive subtitle: "Display menu bar icons hidden behind the notch. Requires Accessibility permission."

### File: `boringNotch/components/Settings/SettingsView.swift`

Add the toggle in the appropriate section. Follow the existing pattern used by other toggles in that file.

## Accessibility (VoiceOver)

- Each icon button has an accessibility label: `"\(item.appName) menu bar item"`
- The row container has accessibility label: "Hidden menu bar icons"
- Buttons are marked as `.accessibilityAddTraits(.isButton)`
